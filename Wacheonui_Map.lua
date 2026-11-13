-- WoW Forever experimental map display. No external processes or network requests.
local panel, heading, rows, pins = nil, nil, {}, {}
local weatherPanel, currentIcon, currentLines
local compactBar, compactIcon, compactText, compactAge
local quickPanel, quickLock, quickScaleText, quickAlphaText, quickAlphaSlider
local FRESH_SECONDS = 1800
local function freshSeconds() return (WacheonuiDB and tonumber(WacheonuiDB.freshSeconds)) or FRESH_SECONDS end
local ICONS = {
  [0] = "Interface\\AddOns\\Wacheonui\\Icons\\Sun",
  [1] = "Interface\\AddOns\\Wacheonui\\Icons\\Rain",
  [2] = "Interface\\AddOns\\Wacheonui\\Icons\\Snow",
  [3] = "Interface\\AddOns\\Wacheonui\\Icons\\Storm",
}
local UNKNOWN_ICON = "Interface\\AddOns\\Wacheonui\\Icons\\Unobserved"
local UNKNOWN = WCN_L("관측 정보가 없습니다.")
local STALE = WCN_L("현지 관측사의 기상 보고가 지연되고 있습니다.")
local lastMap, lastRevision, lastRefresh = nil, -1, 0
local function isNight()
  if type(GetGameTime)~="function" then return false end
  local h=GetGameTime()
  return type(h)=="number" and (h<6 or h>=18)
end
local function iconFor(k)
  if isNight() and k==0 then return "Interface\\AddOns\\Wacheonui\\Icons\\Moon" end
  return ICONS[k] or UNKNOWN_ICON
end
local function label(k)
  if k == 0 then return WCN_L("맑음") elseif k == 1 then return WCN_L("비") elseif k == 2 then return WCN_L("눈") elseif k == 3 then return WCN_L("모래폭풍") end
  return "종류 " .. tostring(k)
end
local function zoneKey(zone, subzone)
  return type(Wacheonui_WeatherZoneKey)=="function" and Wacheonui_WeatherZoneKey(zone,subzone) or zone
end
local function newestByZone()
  local result = {}
  if not WacheonuiDB then return result end
  local function take(r)
    if type(r)=="table" and type(r.zone)=="string" and type(r.at)=="number" and r.at<=time()+30 then
      local key=zoneKey(r.zone,r.subzone)
      if not result[key] or result[key].at<r.at then result[key]=r end
    end
  end
  for _,r in pairs(WacheonuiDB.lastKnown or {}) do take(r) end
  for _,r in ipairs(WacheonuiDB.log or {}) do take(r) end
  return result
end
-- Fade only the weather icon by age. Keep its outline and map background intact.
local function weatherIconAlpha(observedAt)
  if type(observedAt) ~= "number" or observedAt <= 0 then return 0.60 end
  local age = math.max(0, time() - observedAt)
  if age <= 1800 then return 1.00 end
  if age <= 7200 then return 0.90 end
  if age <= 21600 then return 0.80 end
  if age <= 86400 then return 0.70 end
  return 0.60
end
local function ageText(t)
  local sec = math.max(0, time() - (t or 0))
  if sec < 60 then return sec .. WCN_L("초 전") end
  if sec < 3600 then return math.floor(sec/60) .. WCN_L("분 전") end
  if sec < 86400 then return math.floor(sec/3600) .. WCN_L("시간 전") end
  return math.floor(sec/86400) .. WCN_L("일 전")
end
local function showTip(owner, r)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine("와천의 · " .. tostring(r.zone), 0.4, 0.9, 0.8)
  GameTooltip:AddLine("날씨: " .. label(r.kind) .. " / 강도: " .. tostring(r.intensity), 1, 1, 1)
  GameTooltip:AddLine("관측: " .. ageText(r.at), 0.85, 0.85, 0.85)
  if time()-r.at>freshSeconds() then
    GameTooltip:AddLine("오래된 마지막 관측 · 현재 날씨와 다를 수 있음",1,0.7,0.35,true)
  end
  GameTooltip:AddLine(WCN_L("관측사가 파견되었습니다."), 0.5, 0.9, 0.7, true)
  GameTooltip:AddLine(WCN_L("현지 날씨를 기록 중입니다."), 0.85, 0.85, 0.85, true)
  GameTooltip:Show()
end
local function unknownTip(owner, zone)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine("와천의 · " .. tostring(zone), 0.4, 0.9, 0.8)
  GameTooltip:AddLine(UNKNOWN, 1, 0.85, 0.45, true)
  GameTooltip:AddLine(WCN_L("현지 날씨를 조사 중입니다."), 0.7, 0.7, 0.7, true)
  GameTooltip:Show()
end
local function mapID()
  if WorldMapFrame and type(WorldMapFrame.GetMapID) == "function" then
    local ok, id = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
    if ok then return id end
  end
  return nil
end
local function getMapName(id)
  if not C_Map or type(C_Map.GetMapInfo) ~= "function" then return nil end
  local ok, info = pcall(C_Map.GetMapInfo, id)
  if ok and type(info) == "table" then return info.name end
  return nil
end
local function latestLocal(zone)
  if type(Wacheonui_SelectWeather)=="function" then
    local record,conflict=Wacheonui_SelectWeather(zone)
    return record,conflict
  end
  return nil,false
end

local function setText(font, text)
  if font then font:SetText(text) end
end
local function makeText(parent, size, color)
  local t=parent:CreateFontString(nil,"OVERLAY","GameFontNormal")
  t:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
  t:SetTextColor(unpack(color))
  t:SetJustifyH("LEFT")
  return t
end
local function create()
  if not WorldMapFrame then return end
  panel=WorldMapFrame
  if weatherPanel then return end
  weatherPanel=CreateFrame("Frame",nil,WorldMapFrame)
  weatherPanel:SetSize(248,110)
  weatherPanel:SetPoint("TOPRIGHT",WorldMapFrame,"TOPRIGHT",-18,-75)
  weatherPanel:SetMovable(true)
  weatherPanel:SetClampedToScreen(true)
  weatherPanel:EnableMouse(true)
  weatherPanel:RegisterForDrag("LeftButton")
  weatherPanel:SetScript("OnDragStart",function(self)
    if not WacheonuiDB or not WacheonuiDB.panelLocked then
      self:StartMoving()
    end
  end)
  weatherPanel:SetScript("OnDragStop",function(self)
    self:StopMovingOrSizing()
    if WacheonuiDB then
      -- Persist in UIParent coordinates; WorldMapFrame changes size/position by map mode.
      local x,y=self:GetCenter();local px,py=UIParent:GetCenter()
      if x and px and y and py then
        WacheonuiDB.panelScreenX=x-px
        WacheonuiDB.panelScreenY=y-py
        WacheonuiDB.panelX=nil;WacheonuiDB.panelY=nil
        self:ClearAllPoints()
        self:SetPoint("CENTER",UIParent,"CENTER",WacheonuiDB.panelScreenX,WacheonuiDB.panelScreenY)
      end
    end
  end)
  if WacheonuiDB then
    -- Migrate legacy map-relative coordinates once, preserving the visible placement.
    if WacheonuiDB.panelScreenX == nil and WacheonuiDB.panelX ~= nil then
      local mx,my=WorldMapFrame:GetCenter()
      local ux,uy=UIParent:GetCenter()
      if mx and my and ux and uy then
        WacheonuiDB.panelScreenX=mx-ux+WacheonuiDB.panelX
        WacheonuiDB.panelScreenY=my-uy+(WacheonuiDB.panelY or 0)
        WacheonuiDB.panelX=nil;WacheonuiDB.panelY=nil
      end
    end
    if WacheonuiDB.panelScreenX ~= nil then
      weatherPanel:ClearAllPoints()
      weatherPanel:SetPoint("CENTER",UIParent,"CENTER",WacheonuiDB.panelScreenX,WacheonuiDB.panelScreenY or 0)
    end
  end
  weatherPanel:SetScale((WacheonuiDB and WacheonuiDB.panelScale) or 1)
  weatherPanel:SetFrameStrata("HIGH")
  local wb=weatherPanel:CreateTexture(nil,"BACKGROUND")
  wb:SetAllPoints();wb:SetColorTexture(0.025,0.03,0.04,1)
  weatherPanel:SetAlpha((WacheonuiDB and WacheonuiDB.panelAlpha) or 0.9)
  -- The header is a draggable grip on both continent and zone maps.
  -- Frame itself remains draggable outside the grip as well.
  local header=makeText(weatherPanel,12,{1,0.78,0.25})
  header:SetPoint("TOPLEFT",weatherPanel,"TOPLEFT",12,-9)
  header:SetText(WCN_L("현재 지역 날씨"))
  currentIcon=weatherPanel:CreateTexture(nil,"ARTWORK")
  currentIcon:SetSize(44,44);currentIcon:SetPoint("TOPLEFT",weatherPanel,"TOPLEFT",11,-31)
  currentLines={}
  for i=1,3 do
    local line=makeText(weatherPanel,i==1 and 13 or 11,i==1 and {1,1,1} or {0.85,0.85,0.85})
    line:SetPoint("TOPLEFT",weatherPanel,"TOPLEFT",67,-(32+(i-1)*18))
    currentLines[i]=line
  end
  local foot=makeText(weatherPanel,10,{0.7,0.78,0.75})
  foot:SetPoint("BOTTOMLEFT",weatherPanel,"BOTTOMLEFT",12,8)
  foot:SetText(WCN_L("현지 날씨를 조사 중입니다."))
  weatherPanel.foot=foot

  -- Quick settings can be opened directly on continent or zone maps.
  local gearButton=CreateFrame("Button",nil,weatherPanel,"UIPanelButtonTemplate")
  gearButton:SetSize(24,22)
  gearButton:SetPoint("TOPRIGHT",weatherPanel,"TOPRIGHT",-5,-3)
  gearButton:SetText("+")
  gearButton:SetFrameLevel(weatherPanel:GetFrameLevel()+3)
  gearButton:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_LEFT")
    GameTooltip:AddLine(WCN_L("날씨 패널 빠른 설정"))
    GameTooltip:Show()
  end)
  gearButton:SetScript("OnLeave",function() GameTooltip:Hide() end)

  quickPanel=CreateFrame("Frame",nil,WorldMapFrame)
  quickPanel:SetSize(265,205)
  quickPanel:SetFrameStrata("DIALOG")
  quickPanel:SetFrameLevel(weatherPanel:GetFrameLevel()+10)
  quickPanel:SetPoint("TOPRIGHT",WorldMapFrame,"TOPRIGHT",-18,-195)
  quickPanel:EnableMouse(true)
  local qbg=quickPanel:CreateTexture(nil,"BACKGROUND")
  qbg:SetAllPoints();qbg:SetColorTexture(0.025,0.03,0.04,0.96)
  local qtitle=makeText(quickPanel,13,{1,0.83,0.32})
  qtitle:SetPoint("TOPLEFT",quickPanel,"TOPLEFT",12,-12)
  qtitle:SetText(WCN_L("날씨 패널 빠른 설정"))
  local close=CreateFrame("Button",nil,quickPanel,"UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",quickPanel,"TOPRIGHT",2,2)
  quickLock=CreateFrame("CheckButton",nil,quickPanel,"UICheckButtonTemplate")
  quickLock:SetPoint("TOPLEFT",quickPanel,"TOPLEFT",10,-34)
  quickLock:SetSize(23,23)
  local lockText=makeText(quickPanel,11,{1,1,1})
  lockText:SetPoint("LEFT",quickLock,"RIGHT",3,0)
  lockText:SetText(WCN_L("패널 위치 잠금"))
  quickLock:SetScript("OnClick",function(self)
    WacheonuiDB=WacheonuiDB or {}
    WacheonuiDB.panelLocked=self:GetChecked() and true or false
  end)
  local scaleTitle=makeText(quickPanel,11,{1,1,1})
  scaleTitle:SetPoint("TOPLEFT",quickPanel,"TOPLEFT",12,-71)
  scaleTitle:SetText(WCN_L("크기"))
  local minus=CreateFrame("Button",nil,quickPanel,"UIPanelButtonTemplate")
  minus:SetSize(36,22);minus:SetPoint("TOPLEFT",quickPanel,"TOPLEFT",85,-65);minus:SetText("-")
  quickScaleText=makeText(quickPanel,11,{1,1,1})
  quickScaleText:SetWidth(60);quickScaleText:SetJustifyH("CENTER")
  quickScaleText:SetPoint("LEFT",minus,"RIGHT",4,0)
  local plus=CreateFrame("Button",nil,quickPanel,"UIPanelButtonTemplate")
  plus:SetSize(36,22);plus:SetPoint("LEFT",quickScaleText,"RIGHT",4,0);plus:SetText("+")
  local function changeScale(delta)
    WacheonuiDB=WacheonuiDB or {}
    local v=math.max(0.7,math.min(1.5,(tonumber(WacheonuiDB.panelScale) or 1)+delta))
    v=math.floor(v*10+0.5)/10
    WacheonuiDB.panelScale=v
    weatherPanel:SetScale(v)
    quickScaleText:SetText(math.floor(v*100+0.5).."%")
  end
  minus:SetScript("OnClick",function() changeScale(-0.1) end)
  plus:SetScript("OnClick",function() changeScale(0.1) end)
  local alphaTitle=makeText(quickPanel,11,{1,1,1})
  alphaTitle:SetPoint("TOPLEFT",quickPanel,"TOPLEFT",12,-106)
  alphaTitle:SetText(WCN_L("투명도"))
  quickAlphaText=makeText(quickPanel,11,{1,1,1})
  quickAlphaText:SetPoint("TOPRIGHT",quickPanel,"TOPRIGHT",-15,-106)
  quickAlphaSlider=CreateFrame("Slider",nil,quickPanel,"OptionsSliderTemplate")
  quickAlphaSlider:SetPoint("TOPLEFT",quickPanel,"TOPLEFT",16,-130)
  quickAlphaSlider:SetSize(225,16)
  quickAlphaSlider:SetMinMaxValues(0.2,1)
  quickAlphaSlider:SetValueStep(0.05)
  if quickAlphaSlider.SetObeyStepOnDrag then quickAlphaSlider:SetObeyStepOnDrag(true) end
  quickAlphaSlider:SetScript("OnValueChanged",function(self,v)
    v=math.floor(v*20+0.5)/20
    WacheonuiDB=WacheonuiDB or {}
    WacheonuiDB.panelAlpha=v
    weatherPanel:SetAlpha(v)
    quickAlphaText:SetText(math.floor(v*100+0.5).."%")
  end)
  local reset=CreateFrame("Button",nil,quickPanel,"UIPanelButtonTemplate")
  reset:SetSize(231,24);reset:SetPoint("BOTTOM",quickPanel,"BOTTOM",0,12)
  reset:SetText(WCN_L("위치 · 크기 · 투명도 초기화"))
  reset:SetScript("OnClick",function()
    WacheonuiDB=WacheonuiDB or {}
    WacheonuiDB.panelScale=1
    WacheonuiDB.panelAlpha=0.9
    WacheonuiDB.panelLocked=false
    weatherPanel:SetScale(1)
    weatherPanel:SetAlpha(0.9)
    if Wacheonui_ResetPanel then Wacheonui_ResetPanel() end
    quickLock:SetChecked(false)
    quickScaleText:SetText("100%")
    quickAlphaSlider:SetValue(0.9)
  end)
  quickPanel:SetScript("OnShow",function()
    local d=WacheonuiDB or {}
    quickLock:SetChecked(d.panelLocked and true or false)
    quickScaleText:SetText(math.floor((d.panelScale or 1)*100+0.5).."%")
    quickAlphaSlider:SetValue(d.panelAlpha or 0.9)
    quickAlphaText:SetText(math.floor((d.panelAlpha or 0.9)*100+0.5).."%")
  end)
  quickPanel:Hide()
  gearButton:SetScript("OnClick",function()
    if quickPanel:IsShown() then quickPanel:Hide() else quickPanel:Show() end
  end)
end
Wacheonui_SetPanelAlpha = function(v)
  if weatherPanel then weatherPanel:SetAlpha(math.max(0.2,math.min(1,v or 0.9))) end
end
Wacheonui_SetPanelScale = function(v)
  if weatherPanel then weatherPanel:SetScale(v) end
end
Wacheonui_ResetPanel = function()
  if weatherPanel then
    weatherPanel:ClearAllPoints()
    weatherPanel:SetPoint("TOPRIGHT",WorldMapFrame,"TOPRIGHT",-18,-75)
  end
  if WacheonuiDB then
    WacheonuiDB.panelX=nil;WacheonuiDB.panelY=nil
    WacheonuiDB.panelScreenX=nil;WacheonuiDB.panelScreenY=nil
  end
end
-- Compact Questie/small-map presentation. The compact strip is attached to
-- the map canvas, not to a fixed screen coordinate or the quest-list panel.
local function isCompactMap()
  if not WorldMapFrame or not WorldMapFrame:IsShown() then return false end
  local width = WorldMapFrame:GetWidth() or 0
  local scale = WorldMapFrame:GetEffectiveScale() or 1
  -- WorldMapFrame can be scaled by other addons; use effective pixel width.
  return width * scale < 1050
end
local function ensureCompactBar()
  if compactBar or not WorldMapFrame then return end
  compactBar=CreateFrame("Frame",nil,WorldMapFrame)
  compactBar:SetSize(184,30)
  compactBar:SetFrameStrata("HIGH")
  compactBar:SetFrameLevel(WorldMapFrame:GetFrameLevel()+12)
  local bg=compactBar:CreateTexture(nil,"BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.035,0.035,0.035,0.82)
  compactIcon=compactBar:CreateTexture(nil,"ARTWORK")
  compactIcon:SetSize(22,22)
  compactIcon:SetPoint("LEFT",compactBar,"LEFT",6,0)
  compactText=makeText(compactBar,11,{1,1,1})
  compactText:SetPoint("LEFT",compactIcon,"RIGHT",5,0)
  compactText:SetWidth(93)
  compactText:SetJustifyH("LEFT")
  compactAge=makeText(compactBar,9,{0.75,0.8,0.8})
  compactAge:SetPoint("RIGHT",compactBar,"RIGHT",-6,0)
  compactAge:SetWidth(48)
  compactAge:SetJustifyH("RIGHT")
  compactBar:EnableMouse(true)
  compactBar:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
    GameTooltip:AddLine(WCN_L("와천의 · 작은 지도 날씨"),0.4,0.9,0.8)
    GameTooltip:AddLine(WCN_L("현재 지역의 최근 관측 정보를 표시합니다."),1,1,1,true)
    GameTooltip:AddLine(WCN_L("표시 설정: /wcncompact on|off"),0.7,0.7,0.7)
    GameTooltip:Show()
  end)
  compactBar:SetScript("OnLeave",function() GameTooltip:Hide() end)
  compactBar:Hide()
end
local function updateMapPanelMode()
  if not weatherPanel then return end
  local enabled = (not WacheonuiDB or (WacheonuiDB.mapEnabled~=false and WacheonuiDB.showCurrentWeather~=false))
  local compact = isCompactMap()
  if compact then ensureCompactBar() end
  weatherPanel:SetShown(enabled and not compact)
  if quickPanel and compact then quickPanel:Hide() end
  if compactBar then
    local visible = enabled and compact and (not WacheonuiDB or WacheonuiDB.compactWeather~=false)
    compactBar:SetShown(visible)
    if visible then
      local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
      local anchor = canvas or WorldMapFrame
      compactBar:ClearAllPoints()
      compactBar:SetPoint("TOPRIGHT",anchor,"TOPRIGHT",-8,-9)
      local zone=zoneKey(GetZoneText and GetZoneText() or "", GetSubZoneText and GetSubZoneText() or "")
      local r=latestLocal(zone)
      compactIcon:SetTexture(r and iconFor(r.kind) or UNKNOWN_ICON)
      compactIcon:SetAlpha(r and weatherIconAlpha(r.at) or 1)
      compactText:SetText(r and label(r.kind) or WCN_L("미관측"))
      compactAge:SetText(r and ageText(r.at) or "")
    end
  end
end
-- Kept as an independent setting so the minimap weather overlay is unaffected.
SLASH_WACHEONUICOMPACT1="/wcncompact"
SlashCmdList["WACHEONUICOMPACT"]=function(msg)
  WacheonuiDB=WacheonuiDB or {}
  msg=(msg or ""):lower():match("^%s*(.-)%s*$")
  if msg=="on" then WacheonuiDB.compactWeather=true
  elseif msg=="off" then WacheonuiDB.compactWeather=false
  else WacheonuiDB.compactWeather=not (WacheonuiDB.compactWeather~=false) end
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("[와천의] 작은 지도 날씨: "..(WacheonuiDB.compactWeather and "ON" or "OFF")) end
  updateMapPanelMode()
end
local function refreshCurrentWeather()
  if not weatherPanel then return end
  weatherPanel:SetShown(not WacheonuiDB or WacheonuiDB.showCurrentWeather~=false)
  local zone=zoneKey(GetZoneText and GetZoneText() or "", GetSubZoneText and GetSubZoneText() or "")
  if zone=="" then zone=WCN_L("지역 확인 중") end
  local r=latestLocal(zone)
  setText(currentLines[1],zone)
  if r then
    currentIcon:SetTexture(iconFor(r.kind))
    currentIcon:SetAlpha(weatherIconAlpha(r.at))
    setText(currentLines[2],label(r.kind)..(isNight() and WCN_L(" · 밤") or WCN_L(" · 낮")))
    setText(currentLines[3],"최근 관측: "..ageText(r.at))
    weatherPanel.foot:SetText(WCN_L("현지 날씨를 기록 중입니다."))
  else
    currentIcon:SetTexture(UNKNOWN_ICON)
    currentIcon:SetAlpha(1)
    setText(currentLines[2],WCN_L("미관측"))
    setText(currentLines[3],WCN_L("관측 정보가 없습니다."))
    weatherPanel.foot:SetText(WCN_L("현지 날씨를 조사 중입니다."))
  end
end
local fogs = {}
local glows = {}
local function clearGlows()
  for _, glow in ipairs(glows) do glow:Hide() end
end
local function glowFor(i, canvas)
  if glows[i] then return glows[i] end
  local f=CreateFrame("Frame",nil,canvas)
  f:EnableMouse(false)
  local t=f:CreateTexture(nil,"ARTWORK",nil,0)
  t:SetAllPoints()
  t:SetTexture("Interface\\AddOns\\Wacheonui\\Icons\\ObservedGlow.tga")
  t:SetBlendMode("ADD")
  f.texture=t
  glows[i]=f
  return f
end
local function clearFogs()
  for _, fog in ipairs(fogs) do fog:Hide() end
end
local function fogFor(i, canvas)
  if fogs[i] then return fogs[i] end
  local f=CreateFrame("Frame",nil,canvas)
  f:EnableMouse(false)
  local t=f:CreateTexture(nil,"ARTWORK",nil,1)
  t:SetAllPoints()
  t:SetTexture("Interface\\AddOns\\Wacheonui\\Icons\\FogSoft.tga")
  f.texture=t
  fogs[i]=f
  return f
end
local function clearPins()
  for _, pin in ipairs(pins) do pin:Hide() end
end
local function childZoneMapIDs(parent)
  local ids = {}
  if not C_Map or type(C_Map.GetMapChildrenInfo) ~= "function" then return ids end
  local ok, children = pcall(C_Map.GetMapChildrenInfo, parent)
  if not ok or type(children) ~= "table" then return ids end
  for _, info in ipairs(children) do
    if info and info.mapID and info.name then ids[info.name] = info.mapID end
  end
  return ids
end
local function getCenter(child, parent)
  if not C_Map or type(C_Map.GetMapRectOnMap) ~= "function" then return nil end
  local ok, a,b,c,d = pcall(C_Map.GetMapRectOnMap, child, parent)
  if not ok then return nil end
  local x,y
  -- Depending on the client, map rectangles may be returned as two points
  -- or four numeric bounds. Do not draw pins when the shape is unknown.
  if type(a)=="table" and type(b)=="table" and
     type(a.x)=="number" and type(a.y)=="number" and
     type(b.x)=="number" and type(b.y)=="number" then
    x,y=(a.x+b.x)/2,(a.y+b.y)/2
  elseif type(a)=="number" and type(b)=="number" and
         type(c)=="number" and type(d)=="number" then
    x,y=(a+b)/2,(c+d)/2
  end
  if x and y and x>=0 and x<=1 and y>=0 and y<=1 then return x,y end
  return nil
end
local function pinFor(i, canvas)
  if pins[i] then return pins[i] end
  local p = CreateFrame("Button", nil, canvas)
  p:SetSize(28, 28)
  p.icon = p:CreateTexture(nil, "OVERLAY")
  p.icon:SetSize(24, 24)
  p.icon:SetPoint("CENTER", p, "CENTER", 0, 0)
  p.icon:SetTexCoord(0, 1, 0, 1)
  p:SetScript("OnEnter", function(self) if self.record then showTip(self,self.record) else unknownTip(self,self.zone) end end)
  p:SetScript("OnLeave", function() GameTooltip:Hide() end)
  pins[i] = p
  return p
end
Wacheonui_RefreshMap = function()
  if not WorldMapFrame then return end
  create()
  if not panel then return end
  refreshCurrentWeather()
  local enabled = WacheonuiDB and WacheonuiDB.mapEnabled ~= false
  -- Never show/hide WorldMapFrame itself.
  clearPins()
  clearFogs()
  clearGlows()
  updateMapPanelMode()
  if quickPanel and not enabled then quickPanel:Hide() end
  if not enabled or not WorldMapFrame:IsShown() then return end
  local current = mapID()
  local byZone = newestByZone()
  -- Only place map pins when the client provides reliable zone rectangles.
  -- Otherwise keep the observation list rather than inventing coordinates.
  local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
  if not current or not canvas then return end
  local ids = childZoneMapIDs(current)
  local count=0
  local glowCount=0
  -- Only observed child zones receive a small icon halo; unknown zones remain untouched.
  for zone,id in pairs(ids) do
    local x,y = getCenter(id,current)
    if x and y and count<100 then
      count=count+1
      local r=byZone[zoneKey(zone)]
      local p=pinFor(count,canvas)
      p:SetParent(canvas)
      p:ClearAllPoints()
      p:SetPoint("CENTER",canvas,"TOPLEFT",canvas:GetWidth()*x,-canvas:GetHeight()*y)
      p.record=r
      p.zone=zone
      if not r then
        -- Leave never-observed regions exactly as the original parchment map.
        -- No fog, dark tint, question-mark icon, or fake region boundary.
        p:Hide()
      else
        p.icon:SetTexture(iconFor(r.kind))
        p.icon:SetSize(24, 24)
        p:SetAlpha(1)
        p.icon:SetAlpha(weatherIconAlpha(r.at))
        -- Weather icons use baked-in dark/gold outlines for readability.
        -- No extra glow or sparkle: preserve the original parchment map.
        if p.sparkle then p.sparkle:Hide() end
      end
      if r then p:Show() else p:Hide() end
    end
  end
end
local ticker = CreateFrame("Frame")
local elapsed=0
ticker:SetScript("OnUpdate",function(_,dt)
  if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  elapsed=elapsed+dt
  if elapsed<2 then return end
  elapsed=0
  Wacheonui_RefreshMap()
end)
