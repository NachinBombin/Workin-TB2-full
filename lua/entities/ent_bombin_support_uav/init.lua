AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- Permanent yaw correction so the TB-2 mesh faces the direction of travel.
-- Applied unconditionally every tick: self.ang.y = flightYaw + MODEL_YAW_OFFSET.
local MODEL_YAW_OFFSET = 0

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
-- WEAPON TUNING
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

    self.sky       = ground + self.SkyHeightAdd
    self.DieTime   = CurTime() + self.Lifetime
    self.SpawnTime = CurTime()

    -- ---- Orbit setup ----
    -- Coin-flip CW vs CCW. Use CallDir:Angle():Right() as the tangent base so
    -- the tangent is always perpendicular to the approach direction and the
    -- OrbitDirection multiplier is the ONLY thing that decides left vs right.
    -- The old VectorRand()+dot-flip approach accidentally forced the same
    -- half-plane every spawn, overriding OrbitDirection.
    self.OrbitDirection = (math.random(2) == 1) and 1 or -1
    self.OrbitTangent   = self.CallDir:Angle():Right() * self.OrbitDirection

    -- Orbit steering gains
    self.RadialGain   = 0.42
    self.SkyAvoidGain = 0.65
    self.MaxTurnRate  = 28   -- deg/s, slightly tighter than AN-71 for the slower UAV

    -- Spawn offset along tangent so the UAV enters the area naturally
    local spawnOffset = self.OrbitTangent * (-self.OrbitRadius * math.Rand(0.55, 0.95))
    local spawnPos    = self.CenterPos + spawnOffset
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

    -- flightYaw is the pure travel direction.
    -- self.ang.y is always flightYaw + MODEL_YAW_OFFSET (0).
    self.flightYaw = self.OrbitTangent:Angle().y
    self.PrevYaw   = self.flightYaw
    self.ang       = Angle(0, self.flightYaw + MODEL_YAW_OFFSET, 0)
    self:SetAngles(self.ang)

    self.JitterPhase     = math.Rand(0, math.pi * 2)
    self.JitterAmplitude = 8

    self.AltDriftCurrent  = self.sky
    self.AltDriftTarget   = self.sky
    self.AltDriftNextPick = CurTime() + math.Rand(10, 25)
    self.AltDriftRange    = 500
    self.AltDriftLerp     = 0.002

    self.SmoothedRoll  = 0
    self.SmoothedPitch = 0

    -- Tumble state
    self.IsTumbling        = false
    self.TumbleStartTime   = 0
    self.TumbleGroundZ     = ground
    self.TumbleCrashed     = false
    self.TumbleVelocity    = Vector(0, 0, 0)
    self.TumbleAngVelocity = Vector(0, 0, 0)

    self.IsDestroyed = false
    self.DamageTier  = 0

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

    if not HasGred() then
        self:Debug("WARNING: Gredwitch Base not detected — weapons disabled")
    end

    self:Debug("TB-2 spawned at " .. tostring(spawnPos) .. " OrbitDirection=" .. self.OrbitDirection)
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

-- ============================================================
-- TUMBLE SYSTEM
-- ============================================================

function ENT:StartTumble()
    self.IsTumbling      = true
    self.TumbleStartTime = CurTime()
    self.TumbleCrashed   = false

    local gnd = self:FindGround(self:GetPos())
    if gnd ~= -1 then self.TumbleGroundZ = gnd end

    local travelFwd = Angle(0, self.flightYaw, 0):Forward()
    local speed     = self.Speed or 220

    self.TumbleVelocity = Vector(
        travelFwd.x * speed,
        travelFwd.y * speed,
        -200
    )

    local sign = function() return (math.random(2) == 1) and 1 or -1 end
    self.TumbleAngVelocity = Vector(
        math.Rand(80,  200) * sign(),
        math.Rand(20,  80)  * sign(),
        math.Rand(150, 400) * sign()
    )

    local pos = self:GetPos()
    local ed = EffectData()
    ed:SetOrigin(pos)
    ed:SetScale(4) ed:SetMagnitude(4) ed:SetRadius(400)
    util.Effect("500lb_air", ed, true, true)
    sound.Play("ambient/explosions/explode_4.wav", pos, 135, 95, 1.0)
end

function ENT:CrashExplode()
    if self.TumbleCrashed then return end
    self.TumbleCrashed = true

    local pos = self:GetPos()

    local ed1 = EffectData() ed1:SetOrigin(pos)
    ed1:SetScale(6) ed1:SetMagnitude(6) ed1:SetRadius(600)
    util.Effect("HelicopterMegaBomb", ed1, true, true)

    local ed2 = EffectData() ed2:SetOrigin(pos)
    ed2:SetScale(5) ed2:SetMagnitude(5) ed2:SetRadius(500)
    util.Effect("500lb_air", ed2, true, true)

    local ed3 = EffectData() ed3:SetOrigin(pos + Vector(0,0,80))
    ed3:SetScale(4) ed3:SetMagnitude(4) ed3:SetRadius(400)
    util.Effect("500lb_air", ed3, true, true)

    local ed4 = EffectData() ed4:SetOrigin(pos + Vector(0,0,180))
    ed4:SetScale(3) ed4:SetMagnitude(3) ed4:SetRadius(300)
    util.Effect("500lb_air", ed4, true, true)

    sound.Play("ambient/explosions/explode_8.wav", pos, 140, 90, 1.0)
    sound.Play("weapon_AWP.Single",               pos, 145, 60, 1.0)

    util.BlastDamage(self, self, pos, 400, 200)
    self:Remove()
end

function ENT:DestroyUAV()
    if self.IsDestroyed then return end
    self.IsDestroyed = true

    if self.EngineLoop then
        self.EngineLoop:ChangeVolume(0, 0.3)
        timer.Simple(0.4, function()
            if self.EngineLoop then self.EngineLoop:Stop() end
        end)
    end

    self:StartTumble()

    timer.Simple(12, function()
        if IsValid(self) then self:CrashExplode() end
    end)
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
    if not self.DieTime or not self.SpawnTime then
        self:NextThink(CurTime() + 0.1)
        return true
    end

    local ct = CurTime()

    if self.IsTumbling and not self.TumbleCrashed then
        local pos     = self:GetPos()
        local groundZ = self.TumbleGroundZ or -16384

        if pos.z <= groundZ + 150 then
            self:CrashExplode()
            return
        end

        local tr = util.TraceLine({
            start  = pos,
            endpos = pos + Vector(0, 0, -200),
            filter = self,
        })
        if tr.HitWorld then self:CrashExplode() return end

        self:NextThink(ct + 0.05)
        return true
    end

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
-- FLIGHT / TUMBLE PHYSICS
-- ============================================================

function ENT:PhysicsUpdate(phys)
    if not self.DieTime or not self.sky then return end

    -- ---- TUMBLE PATH ----
    if self.IsTumbling then
        if self.TumbleCrashed then return end

        local dt      = engine.TickInterval()
        local gravity = physenv.GetGravity().z

        self.TumbleVelocity.z = self.TumbleVelocity.z + gravity * dt

        local pos    = self:GetPos()
        local newPos = pos + self.TumbleVelocity * dt

        local av   = self.TumbleAngVelocity
        self.ang   = Angle(
            self.ang.p + av.x * dt,
            self.ang.y + av.y * dt,
            self.ang.r + av.z * dt
        )

        self:SetPos(newPos)
        self:SetAngles(self.ang)
        if IsValid(phys) then
            phys:SetPos(newPos)
            phys:SetAngles(self.ang)
        end
        return
    end

    if CurTime() >= self.DieTime then self:Remove() return end

    -- ---- NORMAL FLIGHT PATH ----
    -- Position is integrated here and written once via SetPos/SetAngles.
    -- phys:SetVelocity is intentionally NOT called during normal flight:
    -- calling both SetPos and SetVelocity causes Havok to move the entity
    -- twice per tick (SetPos + velocity integration), producing the
    -- visible teleport/stutter at speed.

    local pos = self:GetPos()
    local dt  = engine.TickInterval()

    -- Altitude drift
    if CurTime() >= self.AltDriftNextPick then
        self.AltDriftTarget   = self.sky + math.Rand(-self.AltDriftRange, self.AltDriftRange)
        self.AltDriftNextPick = CurTime() + math.Rand(10, 25)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)
    self.JitterPhase     = self.JitterPhase + 0.03
    local liveAlt = self.AltDriftCurrent + math.sin(self.JitterPhase) * self.JitterAmplitude

    -- ---- Orbit steering ----
    local flatPos    = Vector(pos.x, pos.y, 0)
    local flatCenter = Vector(self.CenterPos.x, self.CenterPos.y, 0)
    local toCenter   = flatCenter - flatPos
    local dist       = toCenter:Length()

    local radialDir = (dist > 1) and (toCenter / dist) or Vector(0,0,0)
    local tangentDir = Vector(-radialDir.y, radialDir.x, 0) * self.OrbitDirection
    if tangentDir:LengthSqr() <= 0.001 then
        tangentDir = Angle(0, self.flightYaw, 0):Forward()
        tangentDir.z = 0
    end
    tangentDir:Normalize()

    local radialError = 0
    if self.OrbitRadius > 0 then
        radialError = math.Clamp((dist - self.OrbitRadius) / self.OrbitRadius, -1, 1)
    end

    local desiredDir = tangentDir + radialDir * radialError * self.RadialGain

    -- Sky-wall avoidance using the real travel direction
    local fwdProbe  = Angle(0, self.flightYaw, 0):Forward()
    local probeDist = math.max(1000, self.Speed * 5)
    local trFwd   = util.QuickTrace(pos, fwdProbe * probeDist, self)
    local trLeft  = util.QuickTrace(pos, fwdProbe:Angle():Right() * -700 + fwdProbe * 500, self)
    local trRight = util.QuickTrace(pos, fwdProbe:Angle():Right() *  700 + fwdProbe * 500, self)

    local skyAvoid = Vector(0,0,0)
    if trFwd.HitSky   then skyAvoid = skyAvoid - fwdProbe end
    if trLeft.HitSky  then skyAvoid = skyAvoid + fwdProbe:Angle():Right() end
    if trRight.HitSky then skyAvoid = skyAvoid - fwdProbe:Angle():Right() end
    skyAvoid.z = 0
    if skyAvoid:LengthSqr() > 0.001 then
        skyAvoid:Normalize()
        desiredDir = desiredDir + skyAvoid * self.SkyAvoidGain
    end

    desiredDir.z = 0
    if desiredDir:LengthSqr() <= 0.001 then desiredDir = tangentDir end
    desiredDir:Normalize()

    local desiredYaw = desiredDir:Angle().y
    local yawDiff    = math.NormalizeAngle(desiredYaw - self.flightYaw)
    local maxStep    = self.MaxTurnRate * dt
    self.flightYaw   = self.flightYaw + math.Clamp(yawDiff, -maxStep, maxStep)

    -- Roll / pitch smoothing
    local rawYawDelta  = math.NormalizeAngle(self.flightYaw - (self.PrevYaw or self.flightYaw))
    self.PrevYaw       = self.flightYaw

    local targetRoll   = math.Clamp(rawYawDelta * -2.0, -18, 18)
    self.SmoothedRoll  = Lerp(math.abs(rawYawDelta) > 0.01 and 0.10 or 0.04, self.SmoothedRoll, targetRoll)

    local fwdDir       = Angle(0, self.flightYaw, 0):Forward()
    local climbDelta   = math.Clamp((liveAlt - pos.z) / 400, -1, 1)
    self.SmoothedPitch = Lerp(0.04, self.SmoothedPitch, math.Clamp(climbDelta * 6, -8, 8))

    self.ang = Angle(self.SmoothedPitch, self.flightYaw + MODEL_YAW_OFFSET, self.SmoothedRoll)

    -- Single position integration — no phys:SetVelocity
    local newPos = pos + fwdDir * self.Speed * dt
    newPos.z = Lerp(0.08, pos.z, liveAlt)

    if not util.IsInWorld(newPos) then
        local rescueDir = flatCenter - flatPos
        rescueDir.z = 0
        if rescueDir:LengthSqr() <= 0.001 then rescueDir = -fwdDir rescueDir.z = 0 end
        rescueDir:Normalize()
        newPos = pos + rescueDir * self.Speed * dt
        newPos.z = math.min(pos.z, liveAlt)
        self.flightYaw = rescueDir:Angle().y
        self.ang = Angle(self.SmoothedPitch, self.flightYaw + MODEL_YAW_OFFSET, self.SmoothedRoll)
    end

    self:SetPos(newPos)
    self:SetAngles(self.ang)
    if IsValid(phys) then
        phys:SetPos(newPos)
        phys:SetAngles(self.ang)
    end

    if not self:IsInWorld() then
        self:Debug("Out of world — center recovery")
        local safePos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
        self:SetPos(safePos)
        if IsValid(phys) then phys:SetPos(safePos) end
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
    self.CurrentWeapon   = (roll == 1) and "s8_salvo" or "vikhr"
    self.WeaponWindowEnd = ct + self.WeaponWindow
    self:Debug("Weapon: " .. self.CurrentWeapon)

    if self.CurrentWeapon == "s8_salvo" then
        self.S8_ShotsFired  = 0
        self.S8_NextShot    = ct + 0.5
        self.S8_MuzzleIndex = 1
    else
        self.VIKHR_ShotsFired  = 0
        self.VIKHR_NextShot    = ct + 1.0
        self.VIKHR_MuzzleIndex = 1
    end
end

-- ============================================================
-- SLOT 1 — S-8 salvo
-- ============================================================

function ENT:UpdateS8Salvo(ct)
    if self.S8_ShotsFired >= self.S8_Count then return end
    if ct < self.S8_NextShot then return end

    self.S8_NextShot   = ct + self.S8_Delay
    self.S8_ShotsFired = self.S8_ShotsFired + 1

    local muzzleLocal = self.S8_MuzzlePoints[self.S8_MuzzleIndex]
    self.S8_MuzzleIndex = (self.S8_MuzzleIndex % #self.S8_MuzzlePoints) + 1

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
    rocket.IsOnPlane = true
    rocket:Spawn() rocket:Activate()
    rocket.Armed = true rocket.ShouldExplode = true
    rocket:Launch()
    rocket:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    local rPhys = rocket:GetPhysicsObject()
    local uPhys = self:GetPhysicsObject()
    if IsValid(rPhys) and IsValid(uPhys) then rPhys:AddVelocity(uPhys:GetVelocity()) end

    self:SpawnMuzzleFX(muzzlePos)
    sound.Play(table.Random(SOUNDS_ATGM_IGNITE), muzzlePos, 110, math.random(95,105), 1.0)
    timer.Simple(0.1, function() if IsValid(rocket) then sound.Play(table.Random(SOUNDS_LAUNCH), rocket:GetPos(), 105, math.random(95,105), 1.0) end end)

    rocket.IdleSound = CreateSound(rocket, SOUND_ROCKET_IDLE)
    if rocket.IdleSound then rocket.IdleSound:Play() rocket.IdleSound:ChangePitch(math.random(90,115),0) rocket.IdleSound:ChangeVolume(0.8,0) end

    local oldR = rocket.OnRemove
    rocket.OnRemove = function(s) if oldR then oldR(s) end if s.IdleSound then s.IdleSound:Stop() end end
    local oldE = rocket.OnExplode
    rocket.OnExplode = function(s,p,n) if oldE then oldE(s,p,n) end if s.IdleSound then s.IdleSound:Stop() end end

    constraint.NoCollide(rocket, self, 0, 0)
    local ref = rocket
    timer.Simple(0.5, function() if IsValid(ref) and IsValid(self) then constraint.RemoveConstraints(ref,"NoCollide") end end)
end

-- ============================================================
-- SLOT 2 — Vikhr ATGM
-- ============================================================

function ENT:UpdateVikhr(ct)
    if self.VIKHR_ShotsFired >= self.VIKHR_Count then return end
    if ct < self.VIKHR_NextShot then return end

    self.VIKHR_NextShot   = ct + self.VIKHR_Delay
    self.VIKHR_ShotsFired = self.VIKHR_ShotsFired + 1

    local muzzleLocal = self.VIKHR_MuzzlePoints[self.VIKHR_MuzzleIndex]
    self.VIKHR_MuzzleIndex = (self.VIKHR_MuzzleIndex % #self.VIKHR_MuzzlePoints) + 1

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
    rocket.IsOnPlane = true
    rocket:Spawn() rocket:Activate()
    rocket.Armed = true rocket.ShouldExplode = true rocket.ShouldExplodeOnImpact = true
    rocket:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    local startpos = self:LocalToWorld(self:OBBCenter())
    local tr = util.TraceHull({ start=startpos, endpos=startpos+dir*500000, mins=Vector(-25,-25,-25), maxs=Vector(25,25,25), filter=self })

    local rPhys = rocket:GetPhysicsObject()
    local uPhys = self:GetPhysicsObject()
    if IsValid(rPhys) and IsValid(uPhys) then rPhys:AddVelocity(uPhys:GetVelocity()) end

    constraint.NoCollide(rocket, self, 0, 0)
    local ref = rocket
    timer.Simple(0.25, function()
        if not IsValid(ref) then return end
        if tr.Hit then
            ref.JDAM = true ref.target = tr.Entity
            ref.targetOffset = IsValid(tr.Entity) and tr.Entity:WorldToLocal(tr.HitPos) or tr.HitPos
            ref.dropping = true
        end
        ref.Armed = true ref:Launch() ref:SetCollisionGroup(0)
    end)

    self:SpawnMuzzleFX(muzzlePos)
    sound.Play(table.Random(SOUNDS_ATGM_IGNITE), muzzlePos, 0, 100, 1.0)
    timer.Simple(0.1, function() if IsValid(rocket) then sound.Play(table.Random(SOUNDS_LAUNCH), rocket:GetPos(), 105, math.random(95,105), 1.0) end end)

    rocket.IdleSound = CreateSound(rocket, SOUND_ROCKET_IDLE)
    if rocket.IdleSound then rocket.IdleSound:Play() rocket.IdleSound:ChangePitch(math.random(85,110),0) rocket.IdleSound:ChangeVolume(0.9,0) end

    local oldR = rocket.OnRemove
    rocket.OnRemove = function(s) if oldR then oldR(s) end if s.IdleSound then s.IdleSound:Stop() end end
    local oldE = rocket.OnExplode
    rocket.OnExplode = function(s,p,n)
        if oldE then oldE(s,p,n) end
        if s.IdleSound then s.IdleSound:Stop() end
        local hp = p or s:GetPos()
        local e1=EffectData() e1:SetOrigin(hp) e1:SetScale(4) e1:SetMagnitude(4) e1:SetRadius(400) util.Effect("500lb_air",e1,true,true)
        local e2=EffectData() e2:SetOrigin(hp+Vector(0,0,60)) e2:SetScale(3) e2:SetMagnitude(3) e2:SetRadius(300) util.Effect("500lb_air",e2,true,true)
        local e3=EffectData() e3:SetOrigin(hp) e3:SetScale(4) e3:SetMagnitude(4) e3:SetRadius(400) util.Effect("HelicopterMegaBomb",e3,true,true)
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
        else break end
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
