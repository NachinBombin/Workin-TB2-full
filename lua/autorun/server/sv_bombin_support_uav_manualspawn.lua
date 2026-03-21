if not SERVER then return end

util.AddNetworkString("BombinSupportUAV_ManualSpawn")

net.Receive("BombinSupportUAV_ManualSpawn", function(len, ply)
    if not IsValid(ply) then return end

    local tr = util.TraceLine({
        start  = ply:EyePos(),
        endpos = ply:EyePos() + ply:EyeAngles():Forward() * 3000,
        filter = ply,
    })

    local centerPos = tr.Hit and tr.HitPos or (ply:GetPos() + Vector(0, 0, 100))
    local callDir   = ply:EyeAngles():Forward()
    callDir.z = 0
    if callDir:LengthSqr() <= 1 then callDir = Vector(1, 0, 0) end
    callDir:Normalize()

    if not scripted_ents.GetStored("ent_bombin_support_uav") then
        ply:PrintMessage(HUD_PRINTCENTER, "[Bombin UAV] Entity not registered!")
        return
    end

    local uav = ents.Create("ent_bombin_support_uav")
    if not IsValid(uav) then
        ply:PrintMessage(HUD_PRINTCENTER, "[Bombin UAV] Spawn failed!")
        return
    end

    uav:SetPos(centerPos)
    uav:SetAngles(callDir:Angle())
    uav:SetVar("CenterPos",    centerPos)
    uav:SetVar("CallDir",      callDir)
    uav:SetVar("Lifetime",     GetConVar("npc_bombinuav_lifetime"):GetFloat())
    uav:SetVar("Speed",        GetConVar("npc_bombinuav_speed"):GetFloat())
    uav:SetVar("OrbitRadius",  GetConVar("npc_bombinuav_radius"):GetFloat())
    uav:SetVar("SkyHeightAdd", GetConVar("npc_bombinuav_height"):GetFloat())
    uav:Spawn()
    uav:Activate()

    ply:PrintMessage(HUD_PRINTCENTER, "[Bombin UAV] Bayraktar TB-2 inbound!")
end)
