-- Registers ent_bombin_support_uav in the Q menu spawnlist
-- Also adds a control panel for ConVar tuning under Utilities

if not CLIENT then return end

-- ============================================================
-- SPAWNLIST REGISTRATION
-- ============================================================

hook.Add("PopulateContent", "BombinSupportUAV_SpawnMenu", function(pnlContent, tree, node)
    local node = tree:AddNode("Bombin Support", "icon16/bomb.png")

    node:MakePopulator(function(pnlContent)
        -- Heli slot (if the sister addon is also loaded it shares this tree node)
        local helisection = vgui.Create("ContentIcon", pnlContent)
        helisection:SetContentType("entity")
        helisection:SetSpawnName("ent_bombin_support_heli")
        helisection:SetName("Support Helicopter")
        helisection:SetMaterial("entities/ent_bombin_support_heli.png")
        helisection:SetToolTip("Autonomous KA-50 support helicopter.\nOrbits the target area and engages with 30mm cannon, S-8 rockets and Vikhr ATGMs.")
        pnlContent:Add(helisection)

        -- UAV slot — new entry in the same tree node
        local uavsection = vgui.Create("ContentIcon", pnlContent)
        uavsection:SetContentType("entity")
        uavsection:SetSpawnName("ent_bombin_support_uav")
        uavsection:SetName("Support UAV (TB-2)")
        uavsection:SetMaterial("entities/ent_bombin_support_uav.png")
        uavsection:SetToolTip("Autonomous Bayraktar TB-2 UAV support.\nOrbits silently and engages with MAM-L rocket salvos and MAM-C ATGMs.")
        pnlContent:Add(uavsection)
    end)
end)

-- ============================================================
-- CONSOLE COMMAND — manual test spawn
-- ============================================================

concommand.Add("bombin_spawnuav", function()
    if not IsValid(LocalPlayer()) then return end
    net.Start("BombinSupportUAV_ManualSpawn")
    net.SendToServer()
end)

-- ============================================================
-- CONTROL PANEL — Q Menu > Utilities > Bombin Support > UAV TB-2
-- ============================================================

hook.Add("AddToolMenuTabs", "BombinSupportUAV_Tab", function()
    spawnmenu.AddToolTab("Bombin Support", "Bombin Support", "icon16/bomb.png")
end)

hook.Add("AddToolMenuCategories", "BombinSupportUAV_Categories", function()
    spawnmenu.AddToolCategory("Bombin Support", "UAV TB-2", "UAV TB-2")
end)

hook.Add("PopulateToolMenu", "BombinSupportUAV_ToolMenu", function()
    spawnmenu.AddToolMenuOption("Bombin Support", "UAV TB-2", "bombin_support_uav_settings", "Bayraktar TB-2 Settings", "", "", function(panel)
        panel:ClearControls()
        panel:Help("NPC Call Settings")

        panel:CheckBox("Enable NPC calls", "npc_bombinuav_enabled")

        panel:NumSlider("Call chance (per check)",     "npc_bombinuav_chance",   0, 1,    2)
        panel:NumSlider("Check interval (seconds)",   "npc_bombinuav_interval", 1, 60,   0)
        panel:NumSlider("NPC cooldown (seconds)",     "npc_bombinuav_cooldown", 10, 300, 0)
        panel:NumSlider("Min call distance (HU)",     "npc_bombinuav_min_dist", 100, 1000, 0)
        panel:NumSlider("Max call distance (HU)",     "npc_bombinuav_max_dist", 500, 8000, 0)
        panel:NumSlider("Flare → arrival delay (s)",  "npc_bombinuav_delay",    1,  30,   0)

        panel:Help("UAV Behaviour")
        panel:NumSlider("Lifetime (seconds)",         "npc_bombinuav_lifetime", 10, 180,  0)
        panel:NumSlider("Forward speed (HU/s)",       "npc_bombinuav_speed",    50, 600,  0)
        panel:NumSlider("Orbit radius (HU)",          "npc_bombinuav_radius",   500, 8000, 0)
        panel:NumSlider("Altitude above ground (HU)", "npc_bombinuav_height",   500, 8000, 0)

        panel:Help("Debug")
        panel:CheckBox("Enable debug prints", "npc_bombinuav_announce")

        panel:Help("Manual spawn (for testing)")
        panel:Button("Spawn TB-2 UAV now", "bombin_spawnuav")
    end)
end)
