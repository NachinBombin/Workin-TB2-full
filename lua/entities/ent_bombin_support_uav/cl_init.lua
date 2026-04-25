include("shared.lua")

-- ============================================================
-- PRECACHE
-- ============================================================
game.AddParticles("particles/fire_01.pcf")
PrecacheParticleSystem("fire_medium_02")

-- ============================================================
-- DAMAGE TIERS  (TB-2 silhouette: long narrow wings, slim fuselage)
-- Tier 1 (<66% HP): 1 fire on fuselage
-- Tier 2 (<33% HP): 3 fires — fuselage + wing roots
-- Tier 3 (dead):   5 fires — fuselage, wing roots, wingtips
-- ============================================================

local TIER_OFFSETS = {
    [1] = {
        Vector(0, 0, 0),
    },
    [2] = {
        Vector(  0,   0,  0),
        Vector( 10, -70, -3),
        Vector( 10,  70, -3),
    },
    [3] = {
        Vector(  0,   0,  0),
        Vector( 10, -70, -3),
        Vector( 10,  70, -3),
        Vector( 12, -130, -4),
        Vector( 12,  130, -4),
    },
}

local TIER_BURST_DELAY = { [1] = 5.5, [2] = 2.5, [3] = 0.8 }
local TIER_BURST_COUNT = { [1] = 1,   [2] = 2,   [3] = 4   }

local UAVStates = {}

-- ============================================================
-- BURST FX
-- ============================================================
local function BurstAt(wPos, tier)
    local ed = EffectData()
    ed:SetOrigin(wPos)
    ed:SetScale(tier == 3 and math.Rand(0.6, 1.1) or math.Rand(0.3, 0.7))
    ed:SetMagnitude(1)
    ed:SetRadius(tier * 15)
    util.Effect("Explosion", ed)

    local ed2 = EffectData()
    ed2:SetOrigin(wPos)
    ed2:SetNormal(Vector(0, 0, 1))
    ed2:SetScale(tier * 0.25)
    ed2:SetMagnitude(tier * 0.3)
    ed2:SetRadius(14)
    util.Effect("ManhackSparks", ed2)

    if tier >= 2 then
        local ed3 = EffectData()
        ed3:SetOrigin(wPos)
        ed3:SetNormal(VectorRand())
        ed3:SetScale(0.5)
        util.Effect("ElectricSpark", ed3)
    end
end

local function SpawnBurstFX(ent, count, tier)
    if not IsValid(ent) then return end
    local pos = ent:GetPos()
    local ang = ent:GetAngles()

    for _ = 1, count do
        local wPos = LocalToWorld(
            Vector(math.Rand(-20, 20), math.Rand(-140, 140), math.Rand(-5, 10)),
            Angle(0, 0, 0), pos, ang
        )
        BurstAt(wPos, tier)
    end

    -- Wing-tip sparks on tier 3
    if tier == 3 then
        for _, side in ipairs({ Vector(12, -130, -4), Vector(12, 130, -4) }) do
            local wPos = LocalToWorld(side, Angle(0, 0, 0), pos, ang)
            local ed = EffectData()
            ed:SetOrigin(wPos)
            ed:SetScale(0.5)
            ed:SetMagnitude(1)
            ed:SetRadius(20)
            util.Effect("Explosion", ed)
        end
    end
end

-- ============================================================
-- PARTICLE MANAGEMENT
-- ============================================================
local function StopParticles(state)
    if not state.particles then return end
    for _, p in ipairs(state.particles) do
        if IsValid(p) then p:StopEmission() end
    end
    state.particles = {}
end

local function ApplyFlameParticles(ent, state, tier)
    StopParticles(state)
    state.tier = tier
    if not IsValid(ent) or tier == 0 then return end

    for _, off in ipairs(TIER_OFFSETS[tier]) do
        local p = ent:CreateParticleEffect("fire_medium_02", PATTACH_ABSORIGIN_FOLLOW, 0)
        if IsValid(p) then
            p:SetControlPoint(0, ent:LocalToWorld(off))
            table.insert(state.particles, p)
        end
    end

    state.nextBurst = CurTime() + (TIER_BURST_DELAY[tier] or 5)
end

-- ============================================================
-- NET
-- ============================================================
net.Receive("bombin_plane_damage_tier", function()
    local entIndex = net.ReadUInt(16)
    local tier     = net.ReadUInt(2)
    local ent      = Entity(entIndex)

    local state = UAVStates[entIndex]
    if not state then
        state = { tier = 0, particles = {}, nextBurst = 0 }
        UAVStates[entIndex] = state
    end

    if state.tier == tier then return end

    if IsValid(ent) then
        ApplyFlameParticles(ent, state, tier)
        if tier > 0 then SpawnBurstFX(ent, TIER_BURST_COUNT[tier] or 1, tier) end
    else
        state.tier         = tier
        state.pendingApply = true
    end
end)

-- ============================================================
-- THINK — track particles + timed bursts
-- ============================================================
hook.Add("Think", "bombin_tb2_damage_fx", function()
    local ct = CurTime()
    for entIndex, state in pairs(UAVStates) do
        local ent = Entity(entIndex)
        if not IsValid(ent) then
            StopParticles(state)
            UAVStates[entIndex] = nil
        else
            if state.pendingApply then
                state.pendingApply = false
                ApplyFlameParticles(ent, state, state.tier)
            end

            if state.tier > 0 then
                local pos     = ent:GetPos()
                local ang     = ent:GetAngles()
                local offsets = TIER_OFFSETS[state.tier]
                for i, p in ipairs(state.particles) do
                    if IsValid(p) and offsets[i] then
                        p:SetControlPoint(0, LocalToWorld(offsets[i], Angle(0, 0, 0), pos, ang))
                    end
                end

                if ct >= state.nextBurst then
                    SpawnBurstFX(ent, TIER_BURST_COUNT[state.tier] or 1, state.tier)
                    state.nextBurst = ct + (TIER_BURST_DELAY[state.tier] or 5)
                end
            end
        end
    end
end)
