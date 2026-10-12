-- Shark Hub | Prison Life | logic rebuild 1.5 | credits: nerely
-- Obsidian UI by deividcomsono (MIT). No former hub branding is retained.
-- Requires an executor with HttpGet/loadstring. Drawing and hooks are optional; splash uses PNG images.
-- Client attribute changes do not bypass the game's server validation.
--
-- CHANGELOG 1.5 (somente Combat / Gun Mods; design e demais modulos intactos):
--  * FIX tracers de bala invisiveis: Drawing.Line era criado com Transparency=1
--    e nunca era redefinido; agora criado visivel e atualizado (Color/Thickness/
--    Transparency) a cada frame, entao a cor escolhida no colorpicker funciona.
--  * FIX mesmo bug latente nas linhas/textos de ESP (Transparency=1 permanente).
--  * "As vezes a arma nem atira": shoot() reescrito com portoes nomeados
--    (shootGate) + diagnostico acoplado ao botao "Inspect equipped gun",
--    que agora imprime o motivo exato do bloqueio (sem arma, sem alvo, sem
--    municao, rate limit, parede, etc).
--  * Muzzle fallback: se a arma nao tiver Muzzle/Handle, usa a Head; se nem
--    isso existir, usa a posicao da camera em vez de abortar o tiro.
--  * chooseTarget simplificado (2 args, sticky-nearest); targetSince removido.
--  * Mantido: AutoShoot/AutoReload/hit chance/attribute mods/inventory restore.

local env = (getgenv and getgenv()) or _G
if env.SharkHub and env.SharkHub.Unload then pcall(env.SharkHub.Unload) end
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local LP = Players.LocalPlayer
if not LP then warn("[Shark Hub] LocalPlayer indisponivel; execute apos entrar no jogo.") return end
local alive, Library = true, nil
local connections, records, savedAttributes, tracers = {}, {}, {}, {}
local target, lastShot, lastReload, lastMods = nil, 0, 0, 0
local hookInstalled, hookStatus = false, "Desativado"
local silentStats = {Calls=0, Redirects=0, Contract="Nao observado"}
local function gameplayActive()
    return alive and Library and not Library.Unloaded and not Library.Toggled
        and not UIS:GetFocusedTextBox()
end
local fovDrawing
local introBusy = false
local S = {
    Aim = false, Silent = false, AutoShoot = false, WeaponSwitch = false,
    AimSmooth = 10, AimPart = "Head", FOV = 150, ShowFOV = true, HitChance = 100,
    RandomParts = false, ShieldBreaker = false, TargetTeams = "All",
    TeamCheck = true, WallCheck = false, Friends = false, MaxDistance = 1500,
    Chams = false, ChamsIntensity = 65,
    ChamsSpeed = 1.2, ChamsPulse = true, ChamsWalls = false,
    ESP = false, BoxStyle = "Corner", Names = true, Health = true, Distance = true,
    Weapons = true, Tracer = false, TracerOrigin = "Bottom", ESPTextSize = 14, ESPBoxThickness = 1.4,
    FireRate = false, FireRateValue = 0.08, InfiniteAmmo = false, AutoReload = false, ReloadThreshold = 0,
    NoRecoil = false, NoSpread = false, Automatic = false, Pellets = false, PelletCount = 8,
    BulletTracers = false, BulletColor = Color3.fromRGB(35, 115, 235), BulletDuration = 0.3,
    AutoPickup = false, Farm = false, FarmDelay = 2, FarmDiscrete = false, FarmReturn = true,
}
local friendCache, friendPending = {}, {}
local C = {Main = Color3.fromRGB(10, 12, 16), Background = Color3.fromRGB(0, 0, 0),
    Accent = Color3.fromRGB(0, 132, 200), Outline = Color3.fromRGB(18, 26, 34), Font = Color3.fromRGB(230, 240, 250)}
local function notify(text)
    warn("[Shark Hub] " .. tostring(text))
    if Library and not Library.Unloaded then pcall(function() Library:Notify(tostring(text), 6) end)
    else pcall(function() StarterGui:SetCore("SendNotification", {Title="Shark Hub | nerely", Text=tostring(text), Duration=7}) end) end
end
local function connect(signal, fn)
    local c = signal:Connect(fn); table.insert(connections, c); return c
end
local function safeDestroy(item)
    if item then pcall(function() item:Destroy() end) end
end
local function root(character)
    return character and (character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso"))
end
local function gun()
    if not LP.Character then return nil end
    for _, t in ipairs(LP.Character:GetChildren()) do
        if t:IsA("Tool") and (t:GetAttribute("ToolType") == "Gun" or t:GetAttribute("MaxAmmo") ~= nil) then return t end
    end
end
-- Auto weapon switch: se a arma equipada esvaziar (ou nao houver arma), equipa a
-- proxima gun da Backpack. Cooldown evita brigar com troca manual.
local lastWeaponSwitch = 0
local function switchWeapon(now)
    if now - lastWeaponSwitch < 0.8 then return end
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local backpack = LP:FindFirstChildOfClass("Backpack")
    if not hum or not backpack then return end
    local t = gun()
    local empty = not t
    if t then
        local ammo = tonumber(t:GetAttribute("Local_CurrentAmmo") or t:GetAttribute("CurrentAmmo"))
        empty = ammo ~= nil and ammo <= 0
    end
    if not empty then return end
    for _, candidate in ipairs(backpack:GetChildren()) do
        if candidate:IsA("Tool") and (candidate:GetAttribute("ToolType") == "Gun" or candidate:GetAttribute("MaxAmmo") ~= nil) then
            local ammo = tonumber(candidate:GetAttribute("Local_CurrentAmmo") or candidate:GetAttribute("CurrentAmmo"))
            if ammo == nil or ammo > 0 then
                lastWeaponSwitch = now
                pcall(function() hum:EquipTool(candidate) end)
                return
            end
        end
    end
end
local function remote(folder, name)
    local f = RS:FindFirstChild(folder)
    return f and f:FindFirstChild(name)
end
local function invoke(r, ...)
    if not r then return false end
    local args = {...}
    if r:IsA("RemoteEvent") then return pcall(function() r:FireServer(table.unpack(args)) end) end
    if r:IsA("RemoteFunction") then
        task.spawn(function() pcall(function() r:InvokeServer(table.unpack(args)) end) end)
        return true
    end
    return false
end

-- CORE-BEGIN: pure helpers, also exercised by the offline test suite.
local function pulseTransparency(intensity, speed, now, animated)
    local opacity = math.clamp(intensity / 100, 0, 1)
    local pulse = animated and (0.65 + 0.35 * (0.5 + 0.5 * math.sin(now * speed * math.pi * 2))) or 1
    return 1 - opacity * pulse
end
local function withinFOV(x, y, cx, cy, radius)
    return (x-cx)^2 + (y-cy)^2 <= radius^2
end
local function chooseTarget(current, candidates)
    if #candidates == 0 then return nil end
    -- Acquire the nearest target; tie-breaks remain deterministic. Sticky: keeps
    -- the current target while valid; weapon switching is handled separately.
    table.sort(candidates, function(a,b)
        if a.distance == b.distance then return a.player.UserId < b.player.UserId end
        return a.distance < b.distance
    end)
    if current then
        for _, candidate in ipairs(candidates) do
            if candidate.player == current then return current end
        end
    end
    return candidates[1].player
end
local function boxSegments(x, y, w, h, style)
    if style == "2D" then
        return {{x,y,x+w,y},{x+w,y,x+w,y+h},{x+w,y+h,x,y+h},{x,y+h,x,y}}
    end
    local a,b = w * 0.25,h * 0.22
    return {{x,y,x+a,y},{x,y,x,y+b},{x+w,y,x+w-a,y},{x+w,y,x+w,y+b},
        {x,y+h,x+a,y+h},{x,y+h,x,y+h-b},{x+w,y+h,x+w-a,y+h},{x+w,y+h,x+w,y+h-b}}
end
local function attributePlan(s)
    local p = {}
    if s.FireRate then p.FireRate = s.FireRateValue end
    if s.InfiniteAmmo then p.Local_CurrentAmmo = "MAX"; p.CurrentAmmo = "MAX" end
    if s.NoRecoil then p.Recoil=0; p.RecoilAmount=0; p.CameraRecoil=0 end
    if s.NoSpread then p.Spread=0; p.SpreadAngle=0; p.Accuracy=0 end
    if s.Automatic then p.Automatic=true; p.Auto=true; p.AutoFire=true end
    if s.Pellets then p.ProjectileCount=s.PelletCount end
    return p
end
local function applyAttributes(tool, state, store)
    local plan = attributePlan(state)
    local saved = store[tool] or {}; store[tool] = saved
    for key, old in pairs(saved) do
        if plan[key] == nil then pcall(function() tool:SetAttribute(key, old) end); saved[key] = nil end
    end
    for key, value in pairs(plan) do
        local old = tool:GetAttribute(key)
        if old ~= nil then
            if saved[key] == nil then saved[key] = old end
            if value == "MAX" then value = tool:GetAttribute("MaxAmmo") end
            if value ~= nil then pcall(function() tool:SetAttribute(key, value) end) end
        end
    end
end
-- CORE-END

-- ==================== TARGET SELECTION / FILTERS ====================
local function requestFriend(p)
    if friendCache[p.UserId] ~= nil or friendPending[p.UserId] then return end
    friendPending[p.UserId] = true
    task.spawn(function()
        local ok, result = pcall(function() return LP:IsFriendsWithAsync(p.UserId) end)
        if not ok then ok,result=pcall(function() return LP:IsFriendsWith(p.UserId) end) end
        if alive and p.Parent==Players then friendCache[p.UserId] = ok and result or false end
        friendPending[p.UserId] = nil
    end)
end
local function eligible(p)
    if not p or p == LP or p.Parent ~= Players then return false end
    if S.TeamCheck and not LP.Neutral and not p.Neutral and LP.Team and p.Team == LP.Team then return false end
    if S.TargetTeams ~= "All" and (not p.Team or p.Team.Name ~= S.TargetTeams) then return false end
    if S.Friends then requestFriend(p); if friendCache[p.UserId] ~= false then return false end end
    local char = p.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local r = root(char); local own = root(LP.Character)
    if not hum or hum.Health <= 0 or not r or not own then return false end
    return (r.Position - own.Position).Magnitude <= S.MaxDistance
end
local function aimPart(p)
    local char = p and p.Character
    if not char then return nil end
    -- ShieldBreaker: mira no cabo do escudo primeiro para quebra-lo.
    if S.ShieldBreaker then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") and string.find(string.lower(t.Name), "shield") then
                local handle = t:FindFirstChild("Handle")
                if handle and handle:IsA("BasePart") then return handle end
            end
        end
    end
    local name = S.AimPart
    if S.RandomParts then
        local options = {"Head", "Torso", "UpperTorso", "HumanoidRootPart", "Left Arm", "Right Arm", "LeftUpperArm", "RightUpperArm"}
        name = options[math.random(1, #options)]
    end
    local part = char:FindFirstChild(name) or root(char)
    return part and part:IsA("BasePart") and part or nil
end
local function visible(part)
    if not part or not part.Parent then return false end
    if not S.WallCheck then return true end
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignored = {cam}
    if LP.Character then table.insert(ignored, LP.Character) end
    params.FilterDescendantsInstances = ignored
    local hit = workspace:Raycast(cam.CFrame.Position, part.Position - cam.CFrame.Position, params)
    return not hit or hit.Instance:IsDescendantOf(part.Parent)
end
local function screenCenter(cam)
    return cam.ViewportSize.X/2, cam.ViewportSize.Y/2
end
local function targetCandidates(cam)
    local out = {}; local cx,cy = screenCenter(cam)
    for _,p in ipairs(Players:GetPlayers()) do
        if eligible(p) then
            local part = aimPart(p)
            if part then
                local v,on = cam:WorldToViewportPoint(part.Position)
                if on and v.Z > 0 and withinFOV(v.X,v.Y,cx,cy,S.FOV) and visible(part) then
                    table.insert(out,{player=p,distance=(Vector2.new(v.X,v.Y)-Vector2.new(cx,cy)).Magnitude})
                end
            end
        end
    end
    return out
end

-- ==================== PLAYER VISUALS / DRAWING ====================
local drawingOK = Drawing and type(Drawing.new) == "function"
local function draw(kind, props)
    if not drawingOK then return nil end
    local ok,obj = pcall(function() return Drawing.new(kind) end)
    if not ok then return nil end
    for k,v in pairs(props or {}) do pcall(function() obj[k]=v end) end
    return obj
end
local function removeDrawing(d)
    if d then pcall(function() d:Remove() end) end
end
local function newRecord(p)
    local rec={player=p, lines={}, texts={}, health=nil, highlight=nil}
    for i=1,12 do rec.lines[i]=draw("Line",{Thickness=1.4,Visible=false,Transparency=1}) end
    for i=1,3 do rec.texts[i]=draw("Text",{Size=14,Center=true,Outline=true,Visible=false,Transparency=1}) end
    rec.health=draw("Line",{Thickness=3,Visible=false,Transparency=1})
    rec.tracer=draw("Line",{Thickness=1,Visible=false,Transparency=0.7})
    records[p]=rec
    return rec
end
local function hideRecord(rec)
    for _,d in pairs(rec.lines) do d.Visible=false end
    for _,d in pairs(rec.texts) do d.Visible=false end
    if rec.health then rec.health.Visible=false end
    if rec.tracer then rec.tracer.Visible=false end
    if rec.highlight then rec.highlight.Enabled=false end
end
local function deleteRecord(p)
    local rec=records[p]; if not rec then return end
    for _,d in pairs(rec.lines) do removeDrawing(d) end
    for _,d in pairs(rec.texts) do removeDrawing(d) end
    removeDrawing(rec.health); removeDrawing(rec.tracer); safeDestroy(rec.highlight)
    records[p]=nil
end
local edges={{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}
local function characterBox(char, cam)
    local cf,size=char:GetBoundingBox(); local corners={}
    local offsets={{-1,1,-1},{1,1,-1},{1,-1,-1},{-1,-1,-1},{-1,1,1},{1,1,1},{1,-1,1},{-1,-1,1}}
    local minX,minY,maxX,maxY=math.huge,math.huge,-math.huge,-math.huge
    for i,o in ipairs(offsets) do
        local pos=cf:PointToWorldSpace(Vector3.new(o[1]*size.X/2,o[2]*size.Y/2,o[3]*size.Z/2))
        local v=cam:WorldToViewportPoint(pos)
        if v.Z <= 0 then return nil end
        corners[i]=Vector2.new(v.X,v.Y)
        minX=math.min(minX,v.X); minY=math.min(minY,v.Y)
        maxX=math.max(maxX,v.X); maxY=math.max(maxY,v.Y)
    end
    return minX,minY,maxX-minX,maxY-minY,corners
end
-- Automatic visual colors: every player uses their own Roblox TeamColor.
-- Includes neutral players (Roblox supplies their TeamColor as well).
local function playerTeamColor(player)
    return player.TeamColor.Color
end

local function updateRecord(rec,cam,now)
    hideRecord(rec)
    local p=rec.player
    local teamColor=playerTeamColor(p)
    if not eligible(p) then return end
    local char=p.Character; local r=root(char)
    local v,on=cam:WorldToViewportPoint(r.Position)
    if not on or v.Z<=0 then return end
    local cx,cy=screenCenter(cam)
    local part=aimPart(p)
    local aimV=part and cam:WorldToViewportPoint(part.Position)
    local inFOV=aimV and aimV.Z>0 and withinFOV(aimV.X,aimV.Y,cx,cy,S.FOV)
    if S.Chams and inFOV and part and visible(part) then
        if not rec.highlight or rec.highlight.Parent~=char then
            safeDestroy(rec.highlight)
            rec.highlight=Instance.new("Highlight")
            rec.highlight.Name="SharkChams"; rec.highlight.Parent=char
        end
        local h=rec.highlight
        h.Adornee=char; h.FillColor=teamColor; h.OutlineColor=teamColor
        h.FillTransparency=pulseTransparency(S.ChamsIntensity,S.ChamsSpeed,now,S.ChamsPulse)
        h.OutlineTransparency=math.min(1,h.FillTransparency+0.1)
        h.DepthMode=S.ChamsWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
        h.Enabled=true
    end
    if not S.ESP or not drawingOK then return end
    -- Aplica tamanho/espessura ao vivo; drawings sao criados uma vez por jogador.
    for _, d in pairs(rec.lines) do pcall(function() d.Thickness = S.ESPBoxThickness end) end
    for _, d in pairs(rec.texts) do pcall(function() d.Size = S.ESPTextSize end) end
    local x,y,w,h,corners=characterBox(char,cam)
    if not x then return end
    -- FIX 1.5: os drawings nascem com Transparency=1 (escondido); ao tornar
    -- visiveis e preciso derrubar a transparencia, senao ficam invisiveis.
    if S.BoxStyle=="3D" then
        for i,e in ipairs(edges) do
            local d=rec.lines[i]
            if d then d.From=corners[e[1]]; d.To=corners[e[2]]; d.Color=teamColor; d.Transparency=0; d.Visible=true end
        end
    elseif S.BoxStyle~="None" then
        for i,a in ipairs(boxSegments(x,y,w,h,S.BoxStyle)) do
            local d=rec.lines[i]
            if d then d.From=Vector2.new(a[1],a[2]); d.To=Vector2.new(a[3],a[4]); d.Color=teamColor; d.Transparency=0; d.Visible=true end
        end
    end
    local name=rec.texts[1]
    if name and S.Names then name.Text=p.DisplayName.." (@"..p.Name..")"; name.Position=Vector2.new(x+w/2,y-18); name.Color=teamColor; name.Transparency=0; name.Visible=true end
    local bottom={}
    if S.Distance then table.insert(bottom,tostring(math.floor((r.Position-root(LP.Character).Position).Magnitude)).." studs") end
    if S.Weapons then local t=char:FindFirstChildOfClass("Tool"); if t then table.insert(bottom,t.Name) end end
    if rec.texts[2] and #bottom>0 then
        local d=rec.texts[2]; d.Text=table.concat(bottom," | "); d.Position=Vector2.new(x+w/2,y+h+3); d.Color=teamColor; d.Transparency=0; d.Visible=true
    end
    local hum=char:FindFirstChildOfClass("Humanoid")
    if S.Health and rec.health and hum then
        local ratio=math.clamp(hum.Health/math.max(1,hum.MaxHealth),0,1)
        rec.health.From=Vector2.new(x-5,y+h); rec.health.To=Vector2.new(x-5,y+h*(1-ratio))
        rec.health.Color=Color3.fromRGB(255*(1-ratio),220*ratio,65); rec.health.Transparency=0; rec.health.Visible=true
    end
    if S.Tracer and rec.tracer then
        local origin=S.TracerOrigin=="Top" and Vector2.new(cx,0) or S.TracerOrigin=="Center" and Vector2.new(cx,cy) or Vector2.new(cx,cam.ViewportSize.Y)
        rec.tracer.From=origin; rec.tracer.To=Vector2.new(v.X,v.Y); rec.tracer.Color=teamColor; rec.tracer.Transparency=0.3; rec.tracer.Visible=true
    end
end

-- ==================== WEAPON STATE / EFFECTS ====================
local function restoreTools()
    for tool,saved in pairs(savedAttributes) do
        for key,old in pairs(saved) do pcall(function() tool:SetAttribute(key,old) end) end
    end
    table.clear(savedAttributes)
end
-- FIX 1.5: tracer nascia com Transparency=1 (invisivel) e a cor fixa no
-- momento da criacao. Agora nasce visivel e Color/Thickness/Transparency sao
-- re-aplicados a cada frame no loop de runtime, entao o colorpicker funciona.
local function bulletLine(from,to,now)
    if not S.BulletTracers or not drawingOK then return end
    local d=draw("Line",{Thickness=1.5,Color=S.BulletColor,Transparency=0.25,Visible=false})
    if d then table.insert(tracers,{drawing=d,from=from,to=to,expires=now+S.BulletDuration}) end
end
local function reload(now)
    if now-lastReload<1 then return end
    local t=gun(); if not t then return end
    local ammo=tonumber(t:GetAttribute("Local_CurrentAmmo") or t:GetAttribute("CurrentAmmo"))
    if ammo and ammo<=math.max(0, S.ReloadThreshold) then
        lastReload=now
        -- Original adapter calls FuncReload without arguments; server-validated.
        invoke(remote("GunRemotes","FuncReload"))
    end
end
-- Portoes do disparo em ordem. `dry=true` pula rate limit e hit chance (uso
-- apenas no diagnostico, para nao consumir RNG nem bloquear por cooldown).
-- Retorna: ok, motivo, tool, parteDoAlvo, remote.
local function shootGate(now, dry)
    local t = gun()
    if not t then return false, "sem arma equipada" end
    local r = remote("GunRemotes", "ShootEvent")
    if not r then return false, "ShootEvent ausente (ReplicatedStorage.GunRemotes)" end
    if not r:IsA("RemoteEvent") then return false, "ShootEvent nao e RemoteEvent" end
    if not target then return false, "sem alvo dentro do FOV/filtros" end
    if not eligible(target) then return false, "alvo reprovou nos filtros (team/friend/distancia)" end
    local part = aimPart(target)
    if not part then return false, "parte do alvo nao encontrada (" .. tostring(S.AimPart) .. ")" end
    if not visible(part) then return false, "alvo bloqueado por parede (WallCheck ON)" end
    local ammo = tonumber(t:GetAttribute("Local_CurrentAmmo") or t:GetAttribute("CurrentAmmo"))
    if ammo and ammo <= 0 then return false, "sem municao (ative AutoReload ou recarregue)" end
    if not dry then
        local rate = math.clamp(tonumber(t:GetAttribute("FireRate")) or 0.15, 0.04, 5)
        if now - lastShot < rate then return false, "rate limit da arma (" .. tostring(rate) .. "s)" end
        if S.HitChance < 100 and math.random(1, 100) > S.HitChance then
            return false, "hit chance: miss rolado (" .. tostring(S.HitChance) .. "%)"
        end
    end
    return true, "ok", t, part, r
end

local lastShootBlock = "nenhuma tentativa ainda"
local function shoot(now)
    local ok, reason, t, part, r = shootGate(now, false)
    lastShootBlock = reason
    if not ok then return end
    lastShot = now
    -- Origem do projétil: Muzzle > Handle > Head > câmera (nunca aborta por
    -- falta de attachment/parte).
    local muzzle = t:FindFirstChild("Muzzle", true) or t:FindFirstChild("Handle") or LP.Character:FindFirstChild("Head")
    local pos
    if muzzle and muzzle:IsA("Attachment") then pos = muzzle.WorldPosition
    elseif muzzle and muzzle:IsA("BasePart") then pos = muzzle.Position end
    if not pos then
        local cam = workspace.CurrentCamera
        pos = (cam and cam.CFrame.Position) or (root(LP.Character) and root(LP.Character).Position)
    end
    if not pos then return end
    local count = math.clamp(tonumber(t:GetAttribute("ProjectileCount")) or 1, 1, 20)
    local payload = {}
    for _ = 1, count do table.insert(payload, { pos, part.Position, part }) end
    local fired = pcall(function() r:FireServer(payload) end)
    if fired then bulletLine(pos, part.Position, now) end
end
-- Uma unica funcao: localiza castRay, instala o hook (com retentativas) e ativa.
-- Reusa o wrapper ja instalado para nao criar cadeia de hooks. Nunca adivinha
-- assinatura: recusa se houver mais de um castRay.
local function installSilent()
    if not alive then return false end
    if hookInstalled then return true end
    if type(hookfunction) ~= "function" then
        hookStatus="Executor sem hookfunction"; notify(hookStatus); return false
    end
    local ok, result = pcall(function()
        local candidates, seen = {}, {}
        local function add(fn)
            if type(fn)=="function" and not seen[fn] then
                seen[fn]=true; table.insert(candidates,fn)
            end
        end
        if type(getgc)=="function" then
            local success,list=pcall(getgc,true)
            if success and type(list)=="table" then
                for _,fn in pairs(list) do
                    if type(fn)=="function" then
                        local named,name=pcall(function()
                            if debug.info then return debug.info(fn,"n") end
                            return debug.getinfo(fn).name
                        end)
                        if named and name=="castRay" then add(fn) end
                    end
                end
            end
        end
        if type(filtergc)=="function" then
            -- deep=true primeiro (como o adapter original); deep=false como fallback.
            for _, deep in ipairs({true, false}) do
                local success,list=pcall(filtergc,"function",{Name="castRay"},deep)
                if success then
                    if type(list)=="table" then for _,fn in pairs(list) do add(fn) end
                    else add(list) end
                end
            end
        end
        if #candidates==0 then error("castRay nao encontrado; equipe uma arma e tente novamente") end
        if #candidates>1 then error("Multiplos castRay encontrados; hook recusado para evitar assinatura errada") end
        if not alive then error("Hub encerrado") end
        local cast=candidates[1]
        local registry=env.SharkSilentHooks
        if type(registry)~="table" then registry={}; env.SharkSilentHooks=registry end
        local bridge=registry[cast]
        if not bridge then
            bridge={}
            local original
            original=hookfunction(cast,function(...)
                local packed=table.pack(original(...))
                local redirect=bridge.Redirect
                if redirect then
                    local success,replacement=pcall(redirect,packed)
                    if success and replacement then packed=replacement end
                end
                return table.unpack(packed,1,packed.n)
            end)
            if type(original)~="function" then error("hookfunction nao retornou a funcao original") end
            registry[cast]=bridge
        end
        bridge.Redirect=function(packed)
            if not alive then return nil end
            silentStats.Calls=silentStats.Calls+1
            -- Preserve normals, material and every extra return. Unknown layouts
            -- are passed through, not fabricated as a two-value result.
            local compatible=packed.n>=2 and typeof(packed[1])=="Instance"
                and packed[1]:IsA("BasePart") and typeof(packed[2])=="Vector3"
            silentStats.Contract=compatible and "BasePart, Vector3 observado"
                or "Retorno desconhecido/sem hit; preservado"
            if not compatible or not gameplayActive() or not S.Silent then return nil end
            if S.HitChance < 100 and math.random(1, 100) > S.HitChance then return nil end
            if not target or not eligible(target) then return nil end
            local part=aimPart(target)
            if not part or not visible(part) then return nil end
            packed[1]=part; packed[2]=part.Position
            silentStats.Redirects=silentStats.Redirects+1
            return packed
        end
        return true
    end)
    hookInstalled=ok and result==true
    hookStatus=hookInstalled and "Instalado; aguardando disparo para verificar chamadas"
        or "Falha: "..tostring(result)
    notify(hookStatus)
    return hookInstalled
end

-- ==================== ITEM ADAPTER ====================
local pickupBusy,pickupSince=false,0
local function givers()
    local f=workspace:FindFirstChild("Prison_ITEMS")
    return f and f:FindFirstChild("giver")
end
local function pickup(name)
    if pickupBusy then return end
    local folder=givers(); local r=root(LP.Character); local event=remote("Remotes","InteractWithItem")
    if not folder or not r or not event then notify("Givers/InteractWithItem indisponiveis neste servidor."); return end
    local item=folder:FindFirstChild(name)
    if not item then notify("Giver nao encontrado: "..tostring(name)); return end
    local part=item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart",true)
    if not part then return end
    pickupBusy=true; pickupSince=os.clock()
    task.spawn(function()
        local original=r.CFrame
        local ok,err=pcall(function()
            r.CFrame=part.CFrame+Vector3.new(0,3,0)
            task.wait(0.2)
            if alive then invoke(event,part) end
            task.wait(0.3)
        end)
        if r.Parent then pcall(function() r.CFrame=original end) end
        pickupBusy=false
        if not ok then notify("Pickup: "..tostring(err)) end
    end)
end
-- ==================== AUTO FARM (remodulado do Auto Farm V3 original) =====
-- Percorre todos os givers, chama InteractWithItem por item e espera FarmDelay.
-- DiscreteMode: invoca sem teleportar; FarmReturn: volta a posicao inicial ao final.
local farmBusy = false
local function farmOnce()
    if farmBusy then return end
    local folder=givers(); local event=remote("Remotes","InteractWithItem")
    local r=root(LP.Character)
    if not folder or not event or not r then return end
    farmBusy=true
    task.spawn(function()
        local original=r.CFrame
        local ok,err=pcall(function()
            for _, item in ipairs(folder:GetChildren()) do
                if not alive or not S.Farm then break end
                local part=item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart",true)
                if part then
                    if not S.FarmDiscrete then
                        r.CFrame=part.CFrame+Vector3.new(0,3,0)
                        task.wait(0.2)
                    end
                    if alive and S.Farm then invoke(event, part) end
                    task.wait(math.max(0.5, S.FarmDelay))
                end
            end
        end)
        if S.FarmReturn and r.Parent then pcall(function() r.CFrame=original end) end
        farmBusy=false
        if not ok then notify("Farm: "..tostring(err)) end
    end)
end
-- ==================== LIFECYCLE / RESTORE ====================
local function unload()
    if not alive then return end
    alive=false; target=nil
    for _,c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    local list={}; for p in pairs(records) do table.insert(list,p) end
    for _,p in ipairs(list) do deleteRecord(p) end
    for _,t in ipairs(tracers) do removeDrawing(t.drawing) end
    table.clear(tracers); removeDrawing(fovDrawing); restoreTools()
    if introBusy and type(_G.SharkMenuIntroUnload) == "function" then
        pcall(_G.SharkMenuIntroUnload)
    end
    if env.SharkHub and env.SharkHub.Unload==unload then env.SharkHub=nil end
    if Library and not Library.Unloaded then pcall(function() Library:Unload() end) end
    -- Installed castRay hooks remain inert/pass-through, avoiding destructive unhook chains.
end
env.SharkHub={Unload=unload,Settings=S,Version="1.5",Credits="nerely"}

-- ==================== PNG SPLASH / STARTUP ====================
-- Self-contained splash state; no touch/click skip, no leftover progress bar.
local function runSplash()
    --[[
    =========================================================================
     SHARK MENU — INTRO / SPLASH FULLSCREEN
     Splash em tela cheia com as 2 imagens, animação (zoom + drift),
     crossfade entre elas e áudio 9041745502 entrando e saindo em fade.
    =========================================================================

     COMO CARREGAR AS IMAGENS (escolha UMA das duas formas):

      1) ARQUIVO LOCAL (é o que está configurado abaixo)
         O script usa CONFIG.Image1 = "shark_v2.png". Se esse arquivo não existir
         no workspace do executor, ele BAIXA sozinho de CONFIG.Image1Url
         (game:HttpGet -> writefile -> getcustomasset). Ou seja: em geral não
         precisa fazer nada, só rodar.
         Requer executor com writefile + getcustomasset.

      2) ASSET ID (mais seguro, funciona em qualquer executor / celular)
         Suba as 2 imagens no Roblox (Creator Dashboard > Development Items >
         Decals/Images). Depois pegue o ID DA IMAGEM (não do decal!) e cole:
             CONFIG.Image1 = 1234567890
             CONFIG.Image2 = 1234567890

     ÁUDIO: o Roblox só toca áudio que você tem permissão de usar. Se o
     9041745502 for privado/de outra pessoa, a intro roda igual e o script
     avisa no console (F9) que o som não carregou.

     AJUSTE RÁPIDO:
      - ordem das imagens  -> CONFIG.Image1 (aparece 1º) / CONFIG.Image2 (2º)
      - duração            -> HoldTime1, HoldTime2, FadeIn, CrossFade, FadeOut
      - velocidade do áudio-> SoundFadeIn / SoundFadeOut / Volume
      - pular              -> ESPAÇO/ESC/ENTER (AllowSkip). Toque não pula.

     Não foi testado dentro do Roblox; valide o comportamento no seu ambiente.
    =========================================================================
    ]]

    --============================== CONFIG ==================================
    local CONFIG = {
    	-- Imagem 1 (aparece primeiro). Aceita número do asset ou nome de arquivo.
    	Image1 = "shark_v2.png",
    	-- Imagem 2 (aparece depois do crossfade).
    	Image2 = "shark_menu_v2.png",

    	-- Se o arquivo local não existir no executor, o script baixa daqui
    	-- (game:HttpGet -> writefile -> getcustomasset). Deixe "" pra desligar.
    	-- Troque pelas suas URLs se preferir hospedar em outro lugar.
    	Image1Url = "https://storage.googleapis.com/runable-templates/cli-uploads%2FuyutjXBKbfgpu5fJKr0qIWY624ciFtxJ%2Fxp13nL_XmsazNI63dEuz-%2Fshark_v2.png",
    	Image2Url = "https://storage.googleapis.com/runable-templates/cli-uploads%2FuyutjXBKbfgpu5fJKr0qIWY624ciFtxJ%2F0fewamGfPxeUfzUXNCvmZ%2Fshark_menu_v2.png",

    	ScreenColor = Color3.fromRGB(0, 0, 0), -- cor do fundo fullscreen

    	StartDelay = 0.35, -- respiro antes de qualquer coisa aparecer
    	FadeIn = 1.10,     -- fade-in + zoom da imagem 1
    	HoldTime1 = 1.60,  -- tempo parado na imagem 1
    	CrossFade = 1.00,  -- troca em fade da 1 para a 2
    	HoldTime2 = 1.80,  -- tempo parado na imagem 2
    	FadeOut = 0.90,    -- fade final (revela o jogo/hub)

    	BaseSize = 0.72, -- tamanho base da imagem (% da tela, mantém proporção)
    	ZoomFrom = 0.90, -- escala inicial (menor = entra mais de longe)
    	ZoomTo = 1.06,   -- escala final (drift lento durante o hold)

    	-- Áudio
    	SoundId = "rbxassetid://9041745502",
    	Volume = 0.65,
    	SoundStartDelay = 0.40,
    	SoundFadeIn = 2.50,
    	SoundFadeOut = 1.60,

    	-- Pular
    	AllowSkip = true,       -- permite pular por ESPAÇO/ESC/ENTER ou botão
    	ClickToSkip = false,    -- toque/clique na tela NÃO fecha a intro
    	ShowSkipButton = false, -- botão "PULAR" no canto (desligado)
    	SkipText = "PULAR  \226\150\182", -- "PULAR  ►"
    	MaxDuration = 25, -- trava de segurança (segundos) contra intro presa

    	-- Barra de progresso fininha embaixo
    	ShowProgressBar = true,
    	ProgressTransparency = 0.35, -- 0 = sólida, 1 = invisível
    	ProgressHeight = 3,
    }
    --========================================================================

    -- Compatibilidade (Lua puro x Luau)
    local wait = (task and task.wait) or wait
    local spawn = (task and task.spawn) or spawn

    local TweenService = game:GetService("TweenService")
    local UserInputService = game:GetService("UserInputService")
    local SoundService = game:GetService("SoundService")
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer

    --=========================== ESTADO / CONTROLE ==========================
    local finished = false
    local skipRequested = false
    local activeTweens = {}
    local sound, gui, skipInputConn

    local function tw(obj, t, props, style, dir)
    	local info = TweenInfo.new(
    		t,
    		style or Enum.EasingStyle.Quad,
    		dir or Enum.EasingDirection.Out
    	)
    	local tween = TweenService:Create(obj, info, props)
    	tween:Play()
    	table.insert(activeTweens, tween)
    	return tween
    end

    local function instant(obj, props)
    	for k, v in pairs(props) do
    		obj[k] = v
    	end
    end

    -- Espera em fatias curtas para poder abortar no "pular"
    local function sleep(t)
    	local elapsed = 0
    	while elapsed < t do
    		if skipRequested or finished then
    			return true
    		end
    		local dt = math.min(0.05, t - elapsed)
    		wait(dt)
    		elapsed = elapsed + dt
    	end
    	return skipRequested or finished
    end

    local function cancelTweens()
    	for _, t in ipairs(activeTweens) do
    		pcall(function()
    			t:Cancel()
    		end)
    	end
    	activeTweens = {}
    end

    --============================= CARREGAMENTO =============================
    local function downloadToFile(url, filename)
    	if type(writefile) ~= "function" then
    		return false, "executor sem writefile"
    	end

    	local ok, data = pcall(function()
    		return game:HttpGet(url, true)
    	end)
    	if not ok or type(data) ~= "string" or #data < 200 then
    		return false, "download falhou (" .. tostring(data) .. ")"
    	end

    	local okWrite = pcall(function()
    		writefile(filename, data)
    	end)
    	if not okWrite then
    		return false, "writefile falhou"
    	end

    	return true
    end

    local function tryCustomAsset(path)
    	if type(getcustomasset) ~= "function" then
    		return nil
    	end
    	local ok, res = pcall(function()
    		return getcustomasset(path)
    	end)
    	if ok and res then
    		return res
    	end
    	return nil
    end

    local function fileExists(path)
    	if type(isfile) ~= "function" then
    		return nil -- não dá pra saber
    	end
    	local ok, res = pcall(isfile, path)
    	if ok then
    		return res and true or false
    	end
    	return nil
    end

    local function resolveImage(src, url, label)
    	if src == nil then
    		return nil
    	end

    	if type(src) == "number" then
    		return "rbxassetid://" .. tostring(src)
    	end

    	if type(src) ~= "string" or src == "" then
    		return nil
    	end

    	local lower = string.lower(src)
    	if string.find(lower, "rbxassetid://", 1, true)
    		or string.find(lower, "rbxthumb://", 1, true)
    		or string.find(lower, "http", 1, true)
    	then
    		return src
    	end

    	-- Arquivo local: garante que ele existe antes de pedir pro executor.
    	local asset = tryCustomAsset(src)
    	if asset then
    		return asset
    	end

    	local exists = fileExists(src)
    	if exists == false and url and url ~= "" then
    		warn("[SharkMenu Intro] " .. label .. ": '" .. src .. "' não existe, baixando...")
    		local okDl, errDl = downloadToFile(url, src)
    		if okDl then
    			asset = tryCustomAsset(src)
    			if asset then
    				return asset
    			end
    			warn("[SharkMenu Intro] " .. label .. ": baixou mas getcustomasset falhou.")
    		else
    			warn("[SharkMenu Intro] " .. label .. ": " .. tostring(errDl))
    		end
    	elseif exists ~= false and url and url ~= "" then
    		-- não deu pra checar / arquivo existe mas o getcustomasset falhou:
    		-- baixa de novo e tenta uma última vez
    		local okDl = downloadToFile(url, src)
    		if okDl then
    			asset = tryCustomAsset(src)
    			if asset then
    				return asset
    			end
    		end
    	end

    	if type(getcustomasset) ~= "function" then
    		warn("[SharkMenu Intro] " .. label
    			.. ": executor sem getcustomasset — use um asset id do Roblox "
    			.. "(ex: CONFIG." .. label .. " = 1234567890).")
    	else
    		warn("[SharkMenu Intro] " .. label .. ": getcustomasset falhou para '"
    			.. src .. "'. Use um asset id do Roblox se persistir.")
    	end

    	return nil
    end

    local function diagnose()
    	warn("[SharkMenu Intro] executor -> writefile=" .. tostring(type(writefile))
    		.. " isfile=" .. tostring(type(isfile))
    		.. " getcustomasset=" .. tostring(type(getcustomasset))
    		.. " gethui=" .. tostring(type(gethui)))
    end

    local function getGuiParent()
    	local ok, res = pcall(function()
    		return gethui and gethui() or nil
    	end)
    	if ok and res then
    		return res
    	end

    	ok, res = pcall(function()
    		return game:GetService("CoreGui")
    	end)
    	if ok and res then
    		return res
    	end

    	return LocalPlayer:WaitForChild("PlayerGui")
    end

    local function buildGui(image1, image2)
    	gui = Instance.new("ScreenGui")
    	gui.Name = "SharkMenuIntro"
    	gui.ResetOnSpawn = false
    	gui.IgnoreGuiInset = true
    	gui.DisplayOrder = 999999
    	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    	local ok = pcall(function()
    		gui.Parent = getGuiParent()
    	end)
    	if not ok then
    		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    	end

    	-- Fundo fullscreen
    	local root = Instance.new("Frame")
    	root.Name = "Root"
    	root.Size = UDim2.fromScale(1, 1)
    	root.Position = UDim2.fromScale(0, 0)
    	root.BackgroundColor3 = CONFIG.ScreenColor
    	root.BackgroundTransparency = 0
    	root.BorderSizePixel = 0
    	root.ZIndex = 1
    	root.Parent = gui

    	local function makeImage(zindex, asset, opaqueBg)
    		local img = Instance.new("ImageLabel")
    		img.Name = "Img" .. tostring(zindex)
    		img.AnchorPoint = Vector2.new(0.5, 0.5)
    		img.Position = UDim2.fromScale(0.5, 0.5)
    		img.Size = UDim2.fromScale(CONFIG.BaseSize, CONFIG.BaseSize)
    		img.BackgroundColor3 = CONFIG.ScreenColor
    		img.BackgroundTransparency = opaqueBg and 0 or 1
    		img.BorderSizePixel = 0
    		img.ScaleType = Enum.ScaleType.Fit
    		img.ImageTransparency = 1
    		img.ZIndex = zindex
    		if asset then
    			img.Image = asset
    		end
    		img.Parent = root
    		return img
    	end

    	-- Montagem: img2 fica EMBAIXO, já opaca (só escondida), img1 fica POR
    	-- CIMA com fundo preto opaco cobrindo tudo.
    	-- O crossfade então é só a img1 perdendo opacidade (imagem + fundo), o
    	-- que revela a img2 que já está lá. Assim não existe o "cinza" do meio
    	-- que aparece quando as duas ficam a 50% de opacidade ao mesmo tempo.
    	local img2 = makeImage(2, image2, false)
    	local img1 = makeImage(3, image1, true)

    	local startSize = CONFIG.BaseSize * CONFIG.ZoomFrom
    	instant(img1, {
    		ImageTransparency = 1,
    		BackgroundTransparency = 0,
    		Size = UDim2.fromScale(startSize, startSize),
    		Position = UDim2.fromScale(0.5, 0.52),
    	})
    	instant(img2, {
    		ImageTransparency = 0,
    		Size = UDim2.fromScale(startSize, startSize),
    		Position = UDim2.fromScale(0.5, 0.52),
    	})

    	-- Barra de progresso
    	local fill
    	if CONFIG.ShowProgressBar then
    		local track = Instance.new("Frame")
    		track.Name = "ProgressTrack"
    		track.AnchorPoint = Vector2.new(0.5, 0.5)
    		track.Position = UDim2.fromScale(0.5, 0.88)
    		track.Size = UDim2.new(0.55, 0, 0, CONFIG.ProgressHeight)
    		track.BackgroundColor3 = CONFIG.ScreenColor
    		track.BackgroundTransparency = 0.75
    		track.BorderSizePixel = 0
    		track.ZIndex = 4
    		track.Parent = root

    		local corner = Instance.new("UICorner")
    		corner.CornerRadius = UDim.new(1, 0)
    		corner.Parent = track

    		fill = Instance.new("Frame")
    		fill.Name = "Fill"
    		fill.Size = UDim2.fromScale(0, 1)
    		fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    		fill.BackgroundTransparency = CONFIG.ProgressTransparency
    		fill.BorderSizePixel = 0
    		fill.ZIndex = 5
    		fill.Parent = track

    		local corner2 = Instance.new("UICorner")
    		corner2.CornerRadius = UDim.new(1, 0)
    		corner2.Parent = fill
    	end

    	-- Botão pular (desligado por padrão: CONFIG.ShowSkipButton)
    	local skipBtn
    	if CONFIG.AllowSkip and CONFIG.ShowSkipButton then
    		skipBtn = Instance.new("TextButton")
    		skipBtn.Name = "Skip"
    		skipBtn.AnchorPoint = Vector2.new(1, 1)
    		skipBtn.Position = UDim2.new(1, -24, 1, -22)
    		skipBtn.Size = UDim2.new(0, 118, 0, 34)
    		skipBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    		skipBtn.BackgroundTransparency = 0.88
    		skipBtn.BorderSizePixel = 0
    		skipBtn.Text = CONFIG.SkipText
    		skipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    		skipBtn.TextTransparency = 1
    		skipBtn.TextScaled = true
    		skipBtn.AutoButtonColor = false
    		skipBtn.ZIndex = 10
    		skipBtn.Parent = root

    		local okFont = pcall(function()
    			skipBtn.FontFace = Font.new(
    				"rbxasset://fonts/families/GothamSSm.json",
    				Enum.FontWeight.Bold
    			)
    		end)
    		if not okFont then
    			pcall(function()
    				skipBtn.Font = Enum.Font.GothamBold
    			end)
    		end

    		local pad = Instance.new("UIPadding")
    		pad.PaddingLeft = UDim.new(0, 12)
    		pad.PaddingRight = UDim.new(0, 12)
    		pad.Parent = skipBtn

    		local btnCorner = Instance.new("UICorner")
    		btnCorner.CornerRadius = UDim.new(1, 0)
    		btnCorner.Parent = skipBtn

    		skipBtn.Activated:Connect(function()
    			skipRequested = true
    		end)
    	end

    	-- Toque/clique em qualquer lugar também pula
    	if CONFIG.AllowSkip and CONFIG.ClickToSkip then
    		local catcher = Instance.new("TextButton")
    		catcher.Name = "SkipCatcher"
    		catcher.Size = UDim2.fromScale(1, 1)
    		catcher.BackgroundTransparency = 1
    		catcher.Text = ""
    		catcher.AutoButtonColor = false
    		catcher.ZIndex = 9
    		catcher.Parent = root
    		catcher.Activated:Connect(function()
    			skipRequested = true
    		end)
    	end

    	-- Teclado independente de ClickToSkip (toque permanece desativado).
    	if CONFIG.AllowSkip then
    		skipInputConn = UserInputService.InputBegan:Connect(function(input, processed)
    			if processed then
    				return
    			end
    			local t = input.UserInputType
    			local k = input.KeyCode
    			if t == Enum.UserInputType.Keyboard
    				and (k == Enum.KeyCode.Space
    					or k == Enum.KeyCode.Escape
    					or k == Enum.KeyCode.Return)
    			then
    				skipRequested = true
    			end
    		end)
    	end

    	return root, img1, img2, skipBtn, fill
    end

    --============================== ÁUDIO ===================================
    local function buildSound(parent)
    	sound = Instance.new("Sound")
    	sound.Name = "SharkMenuIntroSound"
    	sound.SoundId = CONFIG.SoundId
    	sound.Volume = 0
    	sound.Looped = false
    	sound.Parent = parent

    	local warned = false
    	spawn(function()
    		wait(2.5)
    		if not finished and sound and not warned and not sound.IsLoaded then
    			warned = true
    			warn(
    				"[SharkMenu Intro] áudio " .. CONFIG.SoundId
    				.. " não carregou — provavelmente é privado ou não é seu. "
    				.. "A intro segue normalmente."
    			)
    		end
    	end)

    	return sound
    end

    --============================= ENCERRAMENTO =============================
    local function finish(root, fast)
    	if finished then
    		return
    	end
    	finished = true

    	cancelTweens()

    	-- A barra encerra junto com a sequência, sem esperar o fade do áudio.
    	local progressTrack = root and root:FindFirstChild("ProgressTrack")
    	if progressTrack then
    		if not fast then
    			local fill = progressTrack:FindFirstChild("Fill")
    			if fill then
    				fill.Size = UDim2.fromScale(1, 1)
    			end
    		end
    		progressTrack.Visible = false
    	end

    	if skipInputConn then
    		pcall(function()
    			skipInputConn:Disconnect()
    		end)
    		skipInputConn = nil
    	end

    	local out = fast and 0.30 or CONFIG.FadeOut

    	if sound then
    		pcall(function()
    			tw(sound, fast and 0.35 or CONFIG.SoundFadeOut, { Volume = 0 })
    		end)
    	end

    	pcall(function()
    		-- some com qualquer imagem que ainda esteja visível (inclusive se o
    		-- jogador pulou no meio do fade-in da imagem 1)
    		for _, child in ipairs(root:GetChildren()) do
    			if child:IsA("ImageLabel") then
    				tw(child, out * 0.75, {
    					ImageTransparency = 1,
    					BackgroundTransparency = 1,
    				})
    			end
    		end
    		tw(root, out, { BackgroundTransparency = 1 })
    	end)

    	-- O som termina seu fade separado; a interface não espera o áudio.
    	local endingSound = sound
    	sound = nil
    	if endingSound then
    		task.delay((fast and 0.35 or CONFIG.SoundFadeOut) + 0.1, function()
    			pcall(function()
    				endingSound:Stop()
    				endingSound:Destroy()
    			end)
    		end)
    	end
    	wait(out + 0.05)

    	if gui then
    		pcall(function()
    			gui:Destroy()
    		end)
    		gui = nil
    	end

    	if _G.SharkMenuIntro then
    		_G.SharkMenuIntro.IsPlaying = function()
    			return false
    		end
    	end
    end

    --=============================== INTRO ==================================
    local function playIntro()
    	if _G.SharkMenuIntroUnload then
    		pcall(_G.SharkMenuIntroUnload)
    	end

    	local image1 = resolveImage(CONFIG.Image1, CONFIG.Image1Url, "Image1")
    	local image2 = resolveImage(CONFIG.Image2, CONFIG.Image2Url, "Image2")

    	if not image1 and not image2 then
    		warn("[SharkMenu Intro] nenhuma imagem pôde ser carregada; intro cancelada.")
    		diagnose()
    		return
    	end
    	if not image2 then
    		image2 = image1 -- degrada para imagem única em vez de tela preta
    	end
    	if not image1 then
    		image1 = image2
    	end

    	local root, img1, img2, skipBtn, fill = buildGui(image1, image2)
    	sound = buildSound(SoundService)

    	-- API externa: _G.SharkMenuIntro.Skip()
    	_G.SharkMenuIntro = {
    		Skip = function()
    			skipRequested = true
    		end,
    		IsPlaying = function()
    			return not finished
    		end,
    	}
    	_G.SharkMenuIntroUnload = function()
    		if not finished then
    			finish(root, true)
    		end
    	end

    	-- Trava de segurança: nunca deixa a intro presa na tela
    	spawn(function()
    		wait(CONFIG.MaxDuration)
    		if not finished then
    			warn("[SharkMenu Intro] MaxDuration atingido, encerrando.")
    			skipRequested = true
    		end
    	end)

    	sleep(CONFIG.StartDelay)
    	if skipRequested or finished then
    		finish(root, true)
    		return
    	end

    	-- Áudio entra em fade junto com a imagem 1
    	spawn(function()
    		if sleep(CONFIG.SoundStartDelay) or finished or not sound then
    			return
    		end
    		pcall(function()
    			sound:Play()
    			tw(sound, CONFIG.SoundFadeIn, { Volume = CONFIG.Volume })
    		end)
    	end)

    	-- Completa ao terminar a sequência de imagens, antes do fade final.
    	if fill then
    		local total = CONFIG.FadeIn + CONFIG.HoldTime1 + CONFIG.CrossFade
    			+ CONFIG.HoldTime2
    		pcall(function()
    			tw(fill, total, { Size = UDim2.fromScale(1, 1) },
    				Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
    		end)
    	end

    	-- Botão pular aparece depois do fade-in
    	if skipBtn then
    		spawn(function()
    			wait(CONFIG.FadeIn * 0.6)
    			if finished then
    				return
    			end
    			pcall(function()
    				tw(skipBtn, 0.5, { TextTransparency = 0.25 })
    				tw(skipBtn, 0.5, { BackgroundTransparency = 0.82 })
    			end)
    		end)
    	end

    	-- 1) Fade-in + zoom. As DUAS imagens andam juntas no tamanho/posição:
    	--    a de baixo está escondida, mas se ficar menor que a de cima sobra
    	--    borda dela aparecendo na hora do crossfade.
    	local fullSize = UDim2.fromScale(CONFIG.BaseSize, CONFIG.BaseSize)
    	local center = UDim2.fromScale(0.5, 0.5)

    	tw(img1, CONFIG.FadeIn, {
    		ImageTransparency = 0,
    		Size = fullSize,
    		Position = center,
    	}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

    	tw(img2, CONFIG.FadeIn, {
    		Size = fullSize,
    		Position = center,
    	}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

    	if sleep(CONFIG.FadeIn) then
    		finish(root, true)
    		return
    	end

    	-- 2) Hold na imagem 1 com drift lento (zoom contínuo, as duas juntas)
    	local zoomSize = UDim2.fromScale(
    		CONFIG.BaseSize * CONFIG.ZoomTo,
    		CONFIG.BaseSize * CONFIG.ZoomTo
    	)
    	local driftTime = CONFIG.HoldTime1 + CONFIG.CrossFade + CONFIG.HoldTime2 + 0.4

    	tw(img1, driftTime, { Size = zoomSize },
    		Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    	tw(img2, driftTime, { Size = zoomSize },
    		Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

    	if sleep(CONFIG.HoldTime1) then
    		finish(root, true)
    		return
    	end

    	-- 3) Crossfade: a imagem 1 perde opacidade (imagem E fundo preto) e
    	--    revela a imagem 2 que já está embaixo, opaca. Sem queda de brilho.
    	tw(img1, CONFIG.CrossFade, {
    		ImageTransparency = 1,
    		BackgroundTransparency = 1,
    	}, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

    	if sleep(CONFIG.CrossFade + CONFIG.HoldTime2) then
    		finish(root, true)
    		return
    	end

    	-- 4) Fade final (revela o jogo)
    	finish(root, false)
    end

    playIntro()
end

local function intro()
    if not alive or introBusy then return end
    introBusy = true
    local ok, err = xpcall(runSplash, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    introBusy = false
    if not ok then
        if type(_G.SharkMenuIntroUnload) == "function" then
            pcall(_G.SharkMenuIntroUnload)
        end
        warn("[Shark Hub intro] " .. tostring(err))
    end
end

-- ==================== EXISTING UI / CONTROLS ====================
local function buildUI()
    local source=game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua")
    local chunk,err=loadstring(source)
    if not chunk then error("Obsidian: "..tostring(err)) end
    Library=chunk()
    if type(Library)~="table" or not Library.CreateWindow then error("Resposta Obsidian invalida") end
    local function sharkTheme()
        Library.Scheme.MainColor=C.Main; Library.Scheme.BackgroundColor=C.Background
        Library.Scheme.AccentColor=C.Accent; Library.Scheme.OutlineColor=C.Outline; Library.Scheme.FontColor=C.Font
        Library:UpdateColorsUsingRegistry()
    end
    sharkTheme()
    local Window=Library:CreateWindow({Title="Shark Hub",Footer="Prison Life | nerely | v1.5",Size=UDim2.fromOffset(760,580),
        Icon="https://storage.googleapis.com/runable-templates/cli-uploads%2FSWT8vywkWGZzOi6HWtOmyCGbE6bVm30a%2F3wKiiQOqw8_yYpBH0a49M%2Fshark-logo.png",
        Center=true,AutoShow=true,ToggleKeybind=Enum.KeyCode.RightControl,ShowCustomCursor=false,ShowMobileButtons=true})
    -- Botao arrastavel nativo da Obsidian para abrir/fechar (mobile ja tem Toggle/Lock nativos).
    if not Library.IsMobile then
        local toggleBtn=Library:AddDraggableButton({Text="Shark Hub",Func=function() Library:Toggle() end})
        toggleBtn.Button.Position=UDim2.fromOffset(6,6)
    end
    Library:OnUnload(unload)
    local tabs={Combat=Window:AddTab("Combat"),Visuals=Window:AddTab("Visuals"),Guns=Window:AddTab("Gun Mods"),
        Items=Window:AddTab("Weapons"),Settings=Window:AddTab("Settings")}
    local function toggle(g,key,text,after)
        return g:AddToggle("Shark_"..key,{Text=text,Default=S[key],Callback=function(v) S[key]=v; if after then after(v) end end})
    end
    local function slider(g,key,text,min,max,round,suffix)
        return g:AddSlider("Shark_"..key,{Text=text,Default=S[key],Min=min,Max=max,Rounding=round or 0,Suffix=suffix or "",Callback=function(v) S[key]=v end})
    end
    local function dropdown(g,key,text,values)
        return g:AddDropdown("Shark_"..key,{Text=text,Values=values,Default=S[key],Callback=function(v) S[key]=v end})
    end
    local function color(g,key,text)
        g:AddLabel(text):AddColorPicker("Shark_"..key,{Default=S[key],Callback=function(v) S[key]=v end})
    end
    local aim=tabs.Combat:AddLeftGroupbox("Aim & target switching")
    toggle(aim,"Aim","Camera aim (hold RMB)")
    toggle(aim,"Silent","Silent aim (executor hook)",function(v)
        if v then task.spawn(function()
            -- Uma chamada ativa tudo: hook + retentativas internas (5x, 1s).
            for attempt = 1, 5 do
                if not alive or not S.Silent then break end
                if installSilent() then break end
                if attempt < 5 then task.wait(1) end
            end
            if alive and not hookInstalled then
                S.Silent=false
                local control=Library and Library.Toggles["Shark_Silent"]
                if control then control:SetValue(false) end
            end
        end) end
    end)
    aim:AddButton({Text="Retry silent hook",Func=function() task.spawn(installSilent) end})
    toggle(aim,"AutoShoot","Auto shoot (server-validated)")
    toggle(aim,"WeaponSwitch","Auto switch weapon (empty ammo)")
    slider(aim,"AimSmooth","Camera responsiveness",1,30,0)
    slider(aim,"HitChance","Hit chance",1,100,0,"%")
    toggle(aim,"RandomParts","Randomize body part")
    toggle(aim,"ShieldBreaker","Shield breaker (mira no escudo)")
    dropdown(aim,"AimPart","Target part",{"Head","HumanoidRootPart","Torso","UpperTorso"})
    aim:AddLabel("Auto switch troca para a proxima arma com municao quando a atual esvazia.")
    local filters=tabs.Combat:AddRightGroupbox("Shared filters & FOV")
    toggle(filters,"ShowFOV","Show FOV circle")
    slider(filters,"FOV","FOV radius",25,600,0," px")
    slider(filters,"MaxDistance","Maximum distance",100,5000,0," studs")
    toggle(filters,"TeamCheck","Ignore same team")
    dropdown(filters,"TargetTeams","Only target team",{"All","Guards","Inmates","Criminals"})
    toggle(filters,"WallCheck","Visibility check (aim/chams)")
    toggle(filters,"Friends","Ignore friends (cached async)")
    filters:AddLabel("FOV is centered on the viewport, not the mouse.")
    local chams=tabs.Visuals:AddLeftGroupbox("Ocean FOV chams")
    toggle(chams,"Chams","Enable chams within FOV")
    chams:AddLabel("Cor automatica: TeamColor de cada jogador.")
    slider(chams,"ChamsIntensity","Opacity / intensity",0,100,0,"%")
    toggle(chams,"ChamsPulse","Animated pulse")
    slider(chams,"ChamsSpeed","Pulse frequency",0.1,5,1," Hz")
    toggle(chams,"ChamsWalls","Chams through walls")
    chams:AddLabel("Applies shared filters; respawn/unload cleanup included.")
    local esp=tabs.Visuals:AddRightGroupbox("Player ESP")
    toggle(esp,"ESP","Enable ESP (Drawing required)")
    dropdown(esp,"BoxStyle","Box style",{"None","2D","Corner","3D"})
    esp:AddLabel("Cor automatica: TeamColor de cada jogador.")
    toggle(esp,"Names","Name + username")
    toggle(esp,"Health","Health bar")
    toggle(esp,"Distance","Distance")
    toggle(esp,"Weapons","Equipped weapon")
    toggle(esp,"Tracer","Player tracers")
    dropdown(esp,"TracerOrigin","Tracer origin",{"Bottom","Center","Top"})
    slider(esp,"ESPTextSize","Text size",10,24,0)
    slider(esp,"ESPBoxThickness","Box thickness",1,4,1)
    local mods=tabs.Guns:AddLeftGroupbox("Existing gun attributes only")
    toggle(mods,"FireRate","Modify fire rate")
    slider(mods,"FireRateValue","Fire interval",0.04,1,2," s")
    toggle(mods,"InfiniteAmmo","Keep client ammo at MaxAmmo")
    toggle(mods,"AutoReload","Auto reload when empty")
    slider(mods,"ReloadThreshold","Reload at ammo <=",0,10,0)
    toggle(mods,"NoRecoil","Zero supported recoil attributes")
    toggle(mods,"NoSpread","Zero supported spread attributes")
    toggle(mods,"Automatic","Enable supported automatic attributes")
    toggle(mods,"Pellets","Modify projectile count")
    slider(mods,"PelletCount","Projectile count",1,20,0)
    mods:AddButton({Text="Disable mods & restore original attributes",Func=function()
        for _,k in ipairs({"FireRate","InfiniteAmmo","AutoReload","NoRecoil","NoSpread","Automatic","Pellets"}) do
            S[k]=false; local t=Library.Toggles["Shark_"+k]; if t then t:SetValue(false) end
        end
        restoreTools(); notify("Atributos originais restaurados.")
    end})
    local effects=tabs.Guns:AddRightGroupbox("Bullet effects & diagnostics")
    toggle(effects,"BulletTracers","Auto-shoot bullet tracers")
    color(effects,"BulletColor","Bullet tracer color")
    slider(effects,"BulletDuration","Tracer duration",0.1,2,1," s")
    effects:AddLabel("Visual tracers cover shots sent by this hub only.")
    effects:AddLabel("Server ammo/rate checks are NOT bypassed.")
    effects:AddButton({Text="Inspect equipped gun",Func=function()
        local t=gun(); if not t then notify("Equipe uma arma primeiro."); return end
        local attrs=t:GetAttributes(); local keys={}; for k in pairs(attrs) do table.insert(keys,k) end; table.sort(keys)
        local out={t.Name}; for _,k in ipairs(keys) do table.insert(out,k.."="..tostring(attrs[k])) end
        -- FIX 1.5: diagnostico do disparo junto dos atributos (mesmo botao).
        local gateOk, gateReason = shootGate(os.clock(), true)
        table.insert(out, "shoot gate: " .. (gateOk and "OK (tiro sai)" or "BLOQUEADO -> " .. tostring(gateReason)))
        table.insert(out, "ultimo bloqueio real: " .. tostring(lastShootBlock))
        print("[Shark Hub gun diagnostics]\n"..table.concat(out,"\n")); notify("Atributos de "..t.Name.." enviados ao console (F9).")
    end})
    local items=tabs.Items:AddLeftGroupbox("Weapon givers")
    local names={}; local selected
    local picker=items:AddDropdown("Shark_Giver",{Text="Giver",Values={"Refresh list"},Default=1,Callback=function(v) selected=v end})
    local function refresh()
        table.clear(names); local folder=givers()
        if folder then for _,v in ipairs(folder:GetChildren()) do table.insert(names,v.Name) end end
        table.sort(names); picker:SetValues(#names>0 and names or {"No givers found"})
        if names[1] then picker:SetValue(names[1]) end
    end
    items:AddButton({Text="Refresh givers",Func=refresh})
    items:AddButton({Text="Get selected weapon",Func=function() if selected then pickup(selected) end end})
    toggle(items,"AutoPickup","Auto pickup selected giver (3 s)")
    items:AddLabel("Temporarily moves to the giver, then returns.")
    items:AddLabel("Pickup depends on team/access/server validation.")
    local farm=tabs.Items:AddLeftGroupbox("Auto Farm")
    toggle(farm,"Farm","Auto farm all givers")
    slider(farm,"FarmDelay","Delay per giver",0.5,10,1," s")
    toggle(farm,"FarmDiscrete","Discrete (no teleport)")
    toggle(farm,"FarmReturn","Return to start position")
    local info=tabs.Items:AddRightGroupbox("Prison Life adapter")
    info:AddLabel("GunRemotes: ShootEvent / FuncReload")
    info:AddLabel("Remotes: InteractWithItem")
    info:AddLabel("No automatic killing/farm is enabled by default.")
    info:AddLabel("Missing remotes do not prevent the menu opening.")
    local settings=tabs.Settings:AddLeftGroupbox("Shark Hub | nerely")
    settings:AddLabel("RightCtrl toggles the menu; mobile button from Obsidian.")
    settings:AddButton({Text="Restore Shark palette",Func=sharkTheme})
    settings:AddButton({Text="Replay intro",Func=function() if not introBusy then task.spawn(intro) end end})
    settings:AddButton({Text="Capabilities & target status",Func=function()
        notify("Drawing: "..tostring(not not drawingOK).." | local PNG: "..tostring(type(getcustomasset or getsynasset)=="function").." | target: "..(target and target.Name or "none"))
        notify("Silent: "..hookStatus.." | chamadas: "..silentStats.Calls.." | redirecionamentos: "..silentStats.Redirects)
        notify("Contrato: "..silentStats.Contract.." | candidatos: "..(workspace.CurrentCamera and #targetCandidates(workspace.CurrentCamera) or 0).." | menu aberto: "..tostring(Library.Toggled))
        notify("ShootEvent: "..tostring(remote("GunRemotes","ShootEvent")~=nil).." | FuncReload: "..tostring(remote("GunRemotes","FuncReload")~=nil))
        notify("Ultimo disparo: "..tostring(lastShootBlock))
    end})
    settings:AddButton({Text="Panic / unload and restore",Func=unload})
    settings:AddLabel("Hub credits: nerely\nUI library: Obsidian / deividcomsono (MIT)")
    local config=tabs.Settings:AddRightGroupbox("Configuration")
    config:AddLabel("Optional managers load independently of the hub.")
    config:AddButton({Text="Load config + theme managers",Func=function()
        if env.SharkHub and env.SharkHub.ManagersLoaded then notify("Managers ja carregados."); return end
        task.spawn(function()
            local ok,err=pcall(function()
                if not writefile or not readfile or not makefolder or not isfolder or not listfiles then error("Executor sem APIs de arquivo completas") end
                local theme=loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/ThemeManager.lua"))()
                local save=loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/SaveManager.lua"))()
                if not alive then return end
                theme:SetLibrary(Library); save:SetLibrary(Library)
                theme:SetFolder("SharkHub"); save:SetFolder("SharkHub/PrisonLife")
                save:IgnoreThemeSettings(); theme:SetDefaultTheme({FontColor=C.Font,MainColor=C.Main,AccentColor=C.Accent,BackgroundColor=C.Background,OutlineColor=C.Outline})
                save:BuildConfigSection(tabs.Settings); theme:ApplyToTab(tabs.Settings)
                env.SharkHub.ManagersLoaded=true
            end)
            if not ok then notify("Config managers: "..tostring(err)) end
        end)
    end})
    task.defer(refresh)
    return function() return selected end
end
-- ==================== RUNTIME / CONNECTION OWNERSHIP ====================
local function startRuntime(getSelected)
    fovDrawing=draw("Circle",{Radius=S.FOV,Thickness=1.2,NumSides=96,Filled=false,Color=C.Accent,Transparency=0.8,Visible=false})
    connect(Players.PlayerRemoving,function(p) deleteRecord(p); friendCache[p.UserId]=nil; friendPending[p.UserId]=nil; if target==p then target=nil end end)
    local reportedRender,reportedHeartbeat=false,false
    connect(RunService.RenderStepped,function(dt)
        if not alive then return end
        local ok,err=pcall(function()
            local cam=workspace.CurrentCamera; if not cam then return end
            local now=os.clock(); local cx,cy=screenCenter(cam)
            if fovDrawing then fovDrawing.Position=Vector2.new(cx,cy); fovDrawing.Radius=S.FOV; fovDrawing.Visible=S.ShowFOV end
            if gameplayActive() and (S.Aim or S.Silent or S.AutoShoot) then target=chooseTarget(target,targetCandidates(cam))
            else target=nil end
            if S.Aim and target and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) and not UIS:GetFocusedTextBox() and not Library.Toggled then
                local part=aimPart(target)
                if part then cam.CFrame=cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position,part.Position),1-math.exp(-S.AimSmooth*dt)) end
            end
            if S.Chams or S.ESP then
                for _,p in ipairs(Players:GetPlayers()) do if p~=LP then updateRecord(records[p] or newRecord(p),cam,now) end end
            else for _,rec in pairs(records) do hideRecord(rec) end end
            for i=#tracers,1,-1 do
                local t=tracers[i]
                if now>=t.expires then removeDrawing(t.drawing); table.remove(tracers,i)
                else
                    local a,oa=cam:WorldToViewportPoint(t.from); local b,ob=cam:WorldToViewportPoint(t.to)
                    -- FIX 1.5: aplica cor/espessura/transparencia VIVAS a cada frame
                    t.drawing.Color=S.BulletColor
                    t.drawing.Thickness=1.5
                    t.drawing.Transparency=0.25
                    t.drawing.Visible=oa and ob and a.Z>0 and b.Z>0
                    t.drawing.From=Vector2.new(a.X,a.Y); t.drawing.To=Vector2.new(b.X,b.Y)
                end
            end
        end)
        if not ok and not reportedRender then reportedRender=true; notify("Render error: "..tostring(err)) end
    end)
    connect(RunService.Heartbeat,function()
        if not alive then return end
        local ok,err=pcall(function()
            local now=os.clock()
            if now-lastMods>=0.15 then
                lastMods=now; local present={}
                local containers={}
                local backpack=LP:FindFirstChildOfClass("Backpack")
                if backpack then table.insert(containers,backpack) end
                if LP.Character then table.insert(containers,LP.Character) end
                for _,container in ipairs(containers) do
                    for _,t in ipairs(container:GetChildren()) do
                        if t:IsA("Tool") and (t:GetAttribute("ToolType")=="Gun" or t:GetAttribute("MaxAmmo")~=nil) then
                            present[t]=true; applyAttributes(t,S,savedAttributes)
                        end
                    end
                end
                for t,saved in pairs(savedAttributes) do
                    if not present[t] then for key,old in pairs(saved) do pcall(function() t:SetAttribute(key,old) end) end; savedAttributes[t]=nil end
                end
            end
            if S.AutoReload then reload(now) end
            if S.AutoShoot and gameplayActive() then shoot(now) end
            if S.WeaponSwitch and gameplayActive() then switchWeapon(now) end
            if S.AutoPickup and gameplayActive() and not pickupBusy and now-pickupSince>=3 and getSelected() then pickup(getSelected()) end
            if S.Farm and gameplayActive() and not farmBusy then farmOnce() end
        end)
        if not ok and not reportedHeartbeat then reportedHeartbeat=true; notify("Heartbeat error: "..tostring(err)) end
    end)
end

-- ==================== SEQUENTIAL BOOTSTRAP ====================
local function initialize()
    -- The hub remains hidden until the PNG splash completes or is skipped.
    intro()
    if not alive then return end
    local getSelected = buildUI()
    if not alive then return end
    startRuntime(getSelected)
    notify("Shark Hub carregado | nerely | RightCtrl para abrir/fechar.")
end

local ok,err=xpcall(initialize,function(e)
    return tostring(e).."\n"..debug.traceback()
end)
if not ok then
    notify("Falha ao inicializar: "..tostring(err))
    unload()
end
