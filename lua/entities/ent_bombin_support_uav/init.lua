AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- GRED GUARD
-- ============================================================

local function HasGred()
    return gred and gred.CreateShell
end

-- ============================================================
-- ENGINE SOUND
-- ============================================================

local ENGINE_LOOP_SOUND = "lfs/spitfire/rpm_2.wav"

-- ============================================================
-- WEAPON SOUNDS
-- ============================================================

local SOUNDS_ATGM_IGNITE = {
    "ATGM.wav",
    "ATGM2.wav",
    "ATGM3.wav",
    "ATGM4.wav"
}

local SOUNDS_LAUNCH = {
    "launch1.wav",
    "launch2.wav"
}

local SOUND_ROCKET_IDLE = "rocket_idle.wav"

-- ============================================================
-- WEAPON TUNING  (locals — safe under ogfunc, ENT global is nil at file-exec time)
-- ============================================================

local CFG_WeaponWindow = 10

local CFG_S8_Delay        = 0.4
local CFG_S8_Count        = 4
local CFG_S8_Scatter      = 800
local CFG_S8_MuzzlePoints = {
    Vector(60, -70, -5),
    Vector(60,  70, -5),
}

local CFG_VIKHR_Delay        = 4.0
local CFG_VIKHR_Count        = 2
local CFG_VIKHR_Scatter      = 60
local CFG_VIKHR_MuzzlePoints = {
    Vector(60, -70, -5),
    Vector(60,  70, -5),
}

local CFG_FadeDuration = 3.0
local CFG_MaxHP        = 200

-- ============================================================
-- NET STRING
-- ============================================================
util.AddNetworkString("bombin_plane_damage_tier")

-- ============================================================
-- DAMAGE TIER HELPERS
-- ============================================================

local function CalcTier(hp, maxHP)
    local frac = hp / maxHP
    if frac > 0.66 then return 0
    elseif frac > 0.33 then return 1
    elseif frac > 0 then return 2
    else return 3
    end
end

local function BroadcastTier(ent, tier)
    net.Start("bombin_plane_damage_tier")
        net.WriteUInt(ent:EntIndex(), 16)
        net.WriteUInt(tier, 2)
    net.Broadcast()
end

-- ============================================================
-- INITIALIZE
-- ============================================================

function ENT:Initialize()
    self.CenterPos    = self:GetVar("CenterPos",    self:GetPos())
    self.CallDir      = self:GetVar("CallDir",      Vector(1,0,0))
    self.Lifetime     = self:GetVar("Lifetime",     60)
    self.Speed        = self:GetVar("Speed",        220)
    self.OrbitRadius  = self:GetVar("OrbitRadius",  2800)
    self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 2000)

    self.MaxHP        = CFG_MaxHP
    self.WeaponWindow = CFG_WeaponWindow
    self.FadeDuration = CFG_FadeDuration

    self.S8_Delay        = CFG_S8_Delay
    self.S8_Count        = CFG_S8_Count
    self.S8_Scatter      = CFG_S8_Scatter
    self.S8_MuzzlePoints = CFG_S8_MuzzlePoints

    self.VIKHR_Delay        = CFG_VIKHR_Delay
    self.VIKHR_Count        = CFG_VIKHR_Count
    self.VIKHR_Scatter      = CFG_VIKHR_Scatter
    self.VIKHR_MuzzlePoints = CFG_VIKHR_MuzzlePoints

    if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1,0,0) end
    self.CallDir.z = 0
    self.CallDir:Normalize()

    local ground = self:FindGround(self.CenterPos)
    if ground == -1 then self:Debug("FindGround failed") self:Remove() return end

    self.sky      = ground + self.SkyHeightAdd
    self.DieTime  = CurTime() + self.Lifetime
    self.SpawnTime = CurTime()

    local spawnPos = self.CenterPos - self.CallDir * 2000
    spawnPos = Vector(spawnPos.x, spawnPos.y, self.sky)
    if not util.IsInWorld(spawnPos) then
        spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
    end
    if not util.IsInWorld(spawnPos) then
        self:Debug("Spawn position out of world") self:Remove() return
    end

    self:SetModel("models/bayraktar/bayraktartb2.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)
    self:SetPos(spawnPos)

    self:SetRenderMode(RENDERMODE_TRANSALPHA)
    self:SetColor(Color(255, 255, 255, 0))

    self:SetNWInt("HP",    self.MaxHP)
    self:SetNWInt("MaxHP", self.MaxHP)

    local ang = self.CallDir:Angle()
    self:SetAngles(Angle(0, ang.y + 70, 0))
    self.ang = self:GetAngles()

    self.JitterPhase     = math.Rand(0, math.pi * 2)
    self.JitterAmplitude = 8

    self.AltDriftCurrent  = self.sky
    self.AltDriftTarget   = self.sky
    self.AltDriftNextPick = CurTime() + math.Rand(10, 25)
    self.AltDriftRange    = 500
    self.AltDriftLerp     = 0.002

    self.PhysObj = self:GetPhysicsObject()
    if IsValid(self.PhysObj) then
        self.PhysObj:Wake()
        self.PhysObj:EnableGravity(false)
    end

    self.EngineLoop = CreateSound(game.GetWorld(), ENGINE_LOOP_SOUND)
    if self.EngineLoop then
        self.EngineLoop:SetSoundLevel(0)
        self.EngineLoop:ChangePitch(85, 0)
        self.EngineLoop:ChangeVolume(0.4, 0)
        self.EngineLoop:Play()
    end

    self.CurrentWeapon   = nil
    self.WeaponWindowEnd = 0

    self.S8_ShotsFired  = 0
    self.S8_NextShot    = 0
    self.S8_MuzzleIndex = 1

    self.VIKHR_ShotsFired  = 0
    self.VIKHR_NextShot    = 0
    self.VIKHR_MuzzleIndex = 1

    self.IsDestroyed = false
    self.DamageTier  = 0

    if not HasGred() then
        self:Debug("WARNING: Gredwitch Base not detected — weapons disabled")
    end

    self:Debug("TB-2 spawned at " .. tostring(spawnPos))
end

-- ============================================================
-- DAMAGE HANDLING
-- ============================================================

function ENT:OnTakeDamage(dmginfo)
    if self.IsDestroyed then return end
    if dmginfo:IsDamageType(DMG_CRUSH) then return end

    local hp = self:GetNWInt("HP", self.MaxHP)
    hp = hp - dmginfo:GetDamage()
    self:SetNWInt("HP", hp)
    self:Debug("Hit! HP remaining: " .. tostring(hp))

    local tier = CalcTier(hp, self.MaxHP)
    if tier ~= self.DamageTier then
        self.DamageTier = tier
        BroadcastTier(self, tier)
    end

    if hp <= 0 then
        self:Debug("Shot down!")
        self:DestroyUAV()
    end
end

function ENT:DestroyUAV()
    if self.IsDestroyed then return end
    self.IsDestroyed = true

    local pos = self:GetPos()

    local ed1 = EffectData()
    ed1:SetOrigin(pos)
    ed1:SetScale(4) ed1:SetMagnitude(4) ed1:SetRadius(400)
    util.Effect("HelicopterMegaBomb", ed1, true, true)

    local ed2 = EffectData()
    ed2:SetOrigin(pos)
    ed2:SetScale(3) ed2:SetMagnitude(3) ed2:SetRadius(300)
    util.Effect("500lb_air", ed2, true, true)

    local ed3 = EffectData()
    ed3:SetOrigin(pos + Vector(0,0,60))
    ed3:SetScale(2) ed3:SetMagnitude(2) ed3:SetRadius(200)
    util.Effect("500lb_air", ed3, true, true)

    sound.Play("ambient/explosions/explode_8.wav", pos, 140, 90, 1.0)

    util.BlastDamage(self, self, pos, 250, 80)

    self:Remove()
end

-- ============================================================
-- DEBUG
-- ============================================================

function ENT:Debug(msg)
    print("[Bombin UAV TB-2] " .. tostring(msg))
end

-- ============================================================
-- THINK
-- ============================================================

function ENT:Think()
    local ct = CurTime()

    if ct >= self.DieTime then self:Remove() return end

    if not IsValid(self.PhysObj) then
        self.PhysObj = self:GetPhysicsObject()
    end
    if IsValid(self.PhysObj) and self.PhysObj:IsAsleep() then
        self.PhysObj:Wake()
    end

    local age  = ct - self.SpawnTime
    local left = self.DieTime - ct
    local alpha = 255
    if age < self.FadeDuration then
        alpha = math.Clamp(255 * (age / self.FadeDuration), 0, 255)
    elseif left < self.FadeDuration then
        alpha = math.Clamp(255 * (left / self.FadeDuration), 0, 255)
    end
    self:SetColor(Color(255, 255, 255, math.Round(alpha)))

    self:HandleWeaponWindow(ct)

    self:NextThink(ct)
    return true
end

-- ============================================================
-- FLIGHT
-- ============================================================

function ENT:PhysicsUpdate(phys)
    if CurTime() >= self.DieTime then self:Remove() return end

    local pos = self:GetPos()

    if CurTime() >= self.AltDriftNextPick then
        self.AltDriftTarget   = self.sky + math.Rand(-self.AltDriftRange, self.AltDriftRange)
        self.AltDriftNextPick = CurTime() + math.Rand(10, 25)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)

    self.JitterPhase = self.JitterPhase + 0.03
    local jitter     = math.sin(self.JitterPhase) * self.JitterAmplitude

    local liveAlt = self.AltDriftCurrent + jitter
    self:SetPos(Vector(pos.x, pos.y, liveAlt))
    self:SetAngles(self.ang)

    if IsValid(phys) then
        phys:SetVelocity(self:GetForward() * self.Speed)
    end

    local dist = Vector(pos.x, pos.y, 0):Distance(Vector(self.CenterPos.x, self.CenterPos.y, 0))

    if dist > self.OrbitRadius and (self.TurnDelay or 0) < CurTime() then
        self.ang       = self.ang + Angle(0, 0.1, 0)
        self.TurnDelay = CurTime() + 0.02
    end

    local tr = util.QuickTrace(self:GetPos(), self:GetForward() * 3000, self)
    if tr.HitSky then
        self.ang = self.ang + Angle(0, 0.3, 0)
    end

    if not self:IsInWorld() then
        self:Debug("Out of world — removing")
        self:Remove()
    end
end

-- ============================================================
-- TARGET / MUZZLE HELPERS
-- ============================================================

function ENT:GetPrimaryTarget()
    local closest, closestDist = nil, math.huge
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local d = ply:GetPos():DistToSqr(self.CenterPos)
        if d < closestDist then closestDist = d closest = ply end
    end
    return closest
end

function ENT:GetTargetGroundPos()
    local target = self:GetPrimaryTarget()
    if IsValid(target) then return target:GetPos() end
    local tr = util.QuickTrace(
        Vector(self.CenterPos.x, self.CenterPos.y, self.sky),
        Vector(0, 0, -30000), self
    )
    return tr.HitPos
end

function ENT:GetMuzzleWorldPos(localPoint)
    return self:LocalToWorld(localPoint)
end

function ENT:SpawnMuzzleFX(worldPos)
    local ed = EffectData()
    ed:SetOrigin(worldPos)
    ed:SetAngles(self:GetAngles())
    ed:SetEntity(self)
    util.Effect("gred_particle_aircraft_muzzle", ed, true, true)
end

-- ============================================================
-- WEAPON WINDOW CONTROLLER
-- ============================================================

function ENT:HandleWeaponWindow(ct)
    if not self.CurrentWeapon or ct >= self.WeaponWindowEnd then
        self:PickNewWeapon(ct)
    end

    if self.CurrentWeapon == "s8_salvo" then
        self:UpdateS8Salvo(ct)
    elseif self.CurrentWeapon == "vikhr" then
        self:UpdateVikhr(ct)
    end
end

function ENT:PickNewWeapon(ct)
    local roll = math.random(1, 2)
    if roll == 1 then
        self.CurrentWeapon = "s8_salvo"
    else
        self.CurrentWeapon = "vikhr"
    end

    self.WeaponWindowEnd = ct + self.WeaponWindow
    self:Debug("Weapon: " .. self.CurrentWeapon)

    if self.CurrentWeapon == "s8_salvo" then
        self.S8_ShotsFired  = 0
        self.S8_NextShot    = ct + 0.5
        self.S8_MuzzleIndex = 1
    elseif self.CurrentWeapon == "vikhr" then
        self.VIKHR_ShotsFired  = 0
        self.VIKHR_NextShot    = ct + 1.0
        self.VIKHR_MuzzleIndex = 1
    end
end

-- ============================================================
-- SLOT 1 — MAM-L / S-8 salvo  (gb_s8kom_rocket)
-- ============================================================

function ENT:UpdateS8Salvo(ct)
    if self.S8_ShotsFired >= self.S8_Count then return end
    if ct < self.S8_NextShot then return end

    self.S8_NextShot   = ct + self.S8_Delay
    self.S8_ShotsFired = self.S8_ShotsFired + 1

    local muzzleLocal = self.S8_MuzzlePoints[self.S8_MuzzleIndex]
    self.S8_MuzzleIndex = self.S8_MuzzleIndex + 1
    if self.S8_MuzzleIndex > #self.S8_MuzzlePoints then self.S8_MuzzleIndex = 1 end

    local muzzlePos = self:GetMuzzleWorldPos(muzzleLocal)
    local targetPos = self:GetTargetGroundPos() + Vector(
        math.Rand(-self.S8_Scatter, self.S8_Scatter),
        math.Rand(-self.S8_Scatter, self.S8_Scatter),
        0
    )
    local dir = targetPos - muzzlePos
    if dir:LengthSqr() < 1 then return end
    dir:Normalize()

    local rocket = ents.Create("gb_s8kom_rocket")
    if not IsValid(rocket) then self:Debug("gb_s8kom_rocket failed") return end

    rocket:SetPos(muzzlePos)
    rocket:SetAngles(dir:Angle())
    rocket:SetOwner(self)
    rocket.IsOnPlane     = true
    rocket:Spawn()
    rocket:Activate()
    rocket.Armed         = true
    rocket.ShouldExplode = true
    rocket:Launch()
    rocket:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    local uavPhys = self:GetPhysicsObject()
    local rPhys   = rocket:GetPhysicsObject()
    if IsValid(rPhys) and IsValid(uavPhys) then
        rPhys:AddVelocity(uavPhys:GetVelocity())
    end

    self:SpawnMuzzleFX(muzzlePos)
    sound.Play(table.Random(SOUNDS_ATGM_IGNITE), muzzlePos, 110, math.random(95, 105), 1.0)

    timer.Simple(0.1, function()
        if IsValid(rocket) then
            sound.Play(table.Random(SOUNDS_LAUNCH), rocket:GetPos(), 105, math.random(95, 105), 1.0)
        end
    end)

    rocket.IdleSound = CreateSound(rocket, SOUND_ROCKET_IDLE)
    if rocket.IdleSound then
        rocket.IdleSound:Play()
        rocket.IdleSound:ChangePitch(math.random(90, 115), 0)
        rocket.IdleSound:ChangeVolume(0.8, 0)
    end

    local oldRemove = rocket.OnRemove
    rocket.OnRemove = function(s)
        if oldRemove then oldRemove(s) end
        if s.IdleSound then s.IdleSound:Stop() end
    end

    local oldExplode = rocket.OnExplode
    rocket.OnExplode = function(s, pos, normal)
        if oldExplode then oldExplode(s, pos, normal) end
        if s.IdleSound then s.IdleSound:Stop() end
    end

    constraint.NoCollide(rocket, self, 0, 0)
    local rocketRef = rocket
    timer.Simple(0.5, function()
        if IsValid(rocketRef) and IsValid(self) then
            constraint.RemoveConstraints(rocketRef, "NoCollide")
        end
    end)
end

-- ============================================================
-- SLOT 2 — MAM-C / Vikhr ATGM  (gb_9k121_rocket)
-- ============================================================

function ENT:UpdateVikhr(ct)
    if self.VIKHR_ShotsFired >= self.VIKHR_Count then return end
    if ct < self.VIKHR_NextShot then return end

    self.VIKHR_NextShot    = ct + self.VIKHR_Delay
    self.VIKHR_ShotsFired  = self.VIKHR_ShotsFired + 1

    local muzzleLocal = self.VIKHR_MuzzlePoints[self.VIKHR_MuzzleIndex]
    self.VIKHR_MuzzleIndex = self.VIKHR_MuzzleIndex + 1
    if self.VIKHR_MuzzleIndex > #self.VIKHR_MuzzlePoints then self.VIKHR_MuzzleIndex = 1 end

    local muzzlePos = self:GetMuzzleWorldPos(muzzleLocal)
    local targetPos = self:GetTargetGroundPos() + Vector(
        math.Rand(-self.VIKHR_Scatter, self.VIKHR_Scatter),
        math.Rand(-self.VIKHR_Scatter, self.VIKHR_Scatter),
        0
    )
    local dir = targetPos - muzzlePos
    if dir:LengthSqr() < 1 then return end
    dir:Normalize()

    local rocket = ents.Create("gb_9k121_rocket")
    if not IsValid(rocket) then self:Debug("gb_9k121_rocket failed") return end

    rocket:SetPos(muzzlePos)
    rocket:SetAngles(dir:Angle())
    rocket:SetOwner(self)
    rocket.IsOnPlane             = true
    rocket:Spawn()
    rocket:Activate()
    rocket.Armed                 = true
    rocket.ShouldExplode         = true
    rocket.ShouldExplodeOnImpact = true
    rocket:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    local startpos = self:LocalToWorld(self:OBBCenter())
    local tr = util.TraceHull({
        start  = startpos,
        endpos = startpos + dir * 500000,
        mins   = Vector(-25, -25, -25),
        maxs   = Vector( 25,  25,  25),
        filter = self,
    })

    local uavPhys = self:GetPhysicsObject()
    local rPhys   = rocket:GetPhysicsObject()
    if IsValid(rPhys) and IsValid(uavPhys) then
        rPhys:AddVelocity(uavPhys:GetVelocity())
    end

    constraint.NoCollide(rocket, self, 0, 0)
    local rocketRef = rocket
    timer.Simple(0.25, function()
        if not IsValid(rocketRef) then return end
        if tr.Hit then
            rocketRef.JDAM         = true
            rocketRef.target       = tr.Entity
            rocketRef.targetOffset = IsValid(tr.Entity) and tr.Entity:WorldToLocal(tr.HitPos) or tr.HitPos
            rocketRef.dropping     = true
        end
        rocketRef.Armed = true
        rocketRef:Launch()
        rocketRef:SetCollisionGroup(0)
    end)

    self:SpawnMuzzleFX(muzzlePos)
    sound.Play(table.Random(SOUNDS_ATGM_IGNITE), muzzlePos, 0, 100, 1.0)

    timer.Simple(0.1, function()
        if IsValid(rocket) then
            sound.Play(table.Random(SOUNDS_LAUNCH), rocket:GetPos(), 105, math.random(95, 105), 1.0)
        end
    end)

    rocket.IdleSound = CreateSound(rocket, SOUND_ROCKET_IDLE)
    if rocket.IdleSound then
        rocket.IdleSound:Play()
        rocket.IdleSound:ChangePitch(math.random(85, 110), 0)
        rocket.IdleSound:ChangeVolume(0.9, 0)
    end

    local oldRemove = rocket.OnRemove
    rocket.OnRemove = function(s)
        if oldRemove then oldRemove(s) end
        if s.IdleSound then s.IdleSound:Stop() end
    end

    local oldExplode = rocket.OnExplode
    rocket.OnExplode = function(s, pos, normal)
        if oldExplode then oldExplode(s, pos, normal) end
        if s.IdleSound then s.IdleSound:Stop() end

        local hitPos = pos or s:GetPos()
        local ed1 = EffectData()
        ed1:SetOrigin(hitPos) ed1:SetScale(4) ed1:SetMagnitude(4) ed1:SetRadius(400)
        util.Effect("500lb_air", ed1, true, true)
        local ed2 = EffectData()
        ed2:SetOrigin(hitPos + Vector(0,0,60)) ed2:SetScale(3) ed2:SetMagnitude(3) ed2:SetRadius(300)
        util.Effect("500lb_air", ed2, true, true)
        local ed3 = EffectData()
        ed3:SetOrigin(hitPos) ed3:SetScale(4) ed3:SetMagnitude(4) ed3:SetRadius(400)
        util.Effect("HelicopterMegaBomb", ed3, true, true)
    end
end

-- ============================================================
-- GROUND FINDER
-- ============================================================

function ENT:FindGround(centerPos)
    local startPos   = Vector(centerPos.x, centerPos.y, centerPos.z + 64)
    local endPos     = Vector(centerPos.x, centerPos.y, -16384)
    local filterList = { self }
    local maxIter    = 0

    while maxIter < 100 do
        local tr = util.TraceLine({ start = startPos, endpos = endPos, filter = filterList })
        if tr.HitWorld then return tr.HitPos.z end
        if IsValid(tr.Entity) then
            table.insert(filterList, tr.Entity)
        else
            break
        end
        maxIter = maxIter + 1
    end

    return -1
end

-- ============================================================
-- CLEANUP
-- ============================================================

function ENT:OnRemove()
    if self.EngineLoop then
        self.EngineLoop:ChangeVolume(0, 0.5)
        timer.Simple(0.6, function()
            if self.EngineLoop then self.EngineLoop:Stop() end
        end)
    end
end