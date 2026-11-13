-- Wacheonui v0.9.0 usability controls; WoW Forever experimental client.
local root, output, minimapWeather, minimapSettings, minimapOverlay, overlayAnchor
local updateMini
local function db() WacheonuiDB=WacheonuiDB or {}; return WacheonuiDB end
local function makeButton(parent, text, x, y, width, fn)
  local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
  b:SetSize(width or 130,24);b:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
  b:SetText(text);b:SetScript("OnClick",fn)
  return b
end
local function showOutput(t)
  if output then output:SetText(t or "");output:HighlightText(0,0) end
end
local function execute(cmd)
  if Wacheonui_RunCommand then Wacheonui_RunCommand(cmd) end
  if cmd=="netstatus" or cmd=="syncstatus" then showOutput((Wacheonui_GetDiagnostics and Wacheonui_GetDiagnostics()) or WCN_L("결과는 채팅창에서 확인"))
  else showOutput("/wcn "..cmd.." 실행 완료. 상세 결과는 채팅창에서 확인하세요.\n진단 결과는 통신 상태 버튼에서 확인 가능합니다.") end
end
local function addCheck(parent,text,x,y,key,callback)
  local c=CreateFrame("CheckButton",nil,parent,"UICheckButtonTemplate")
  c:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y);c:SetSize(24,24)
  local label=parent:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  label:SetPoint("LEFT",c,"RIGHT",3,0);label:SetText(text)
  c:SetChecked(db()[key]~=false)
  c:SetScript("OnClick",function(self) db()[key]=self:GetChecked() and true or false;if callback then callback() end end)
  return c
end

-- Manual discovery/report dialog: user-controlled, never automatically broadcasts reports.
local reportFrame, reportType, reportNote, reportExport
local reportTypes={
  {"thunder",WCN_L("천둥")},{"lightning",WCN_L("번개")},{"wind",WCN_L("강풍")},{"fog",WCN_L("안개")},{"other",WCN_L("기타 / 새로운 현상")}
}
local function reportText()
  local d=db()
  local lines={"WACHEONUI WEATHER REPORT (manual / not verified)"}
  local r=d.reports and d.reports[#d.reports]
  local snap=d.weatherSnapshots and d.weatherSnapshots[#d.weatherSnapshots]
  if r then
    lines[#lines+1]="Observed: "..date("%Y-%m-%d %H:%M:%S",r.at or time())
    lines[#lines+1]="Zone: "..tostring(r.zone or "?").." / "..tostring(r.subzone or "")
    lines[#lines+1]="Visual: "..tostring(r.label or r.kind or "?")
    lines[#lines+1]="Note: "..tostring(r.note or "")
  else
    lines[#lines+1]="No manual report saved"
  end
  if snap then
    lines[#lines+1]="API sample: "..date("%Y-%m-%d %H:%M:%S",snap.at or time())
    lines[#lines+1]="API zone: "..tostring(snap.zone or "?")
    lines[#lines+1]="API type="..tostring(snap.kind).." intensity="..tostring(snap.intensity)
    lines[#lines+1]="Build: "..tostring(snap.build or "?")
    if r and (r.zone~=snap.zone or math.abs((r.at or 0)-(snap.at or 0))>300) then
      lines[#lines+1]="WARNING: API sample is from another zone or over 5 minutes apart"
    end
  else
    lines[#lines+1]="API sample: none (use Capture API first)"
  end
  lines[#lines+1]="This report is locally saved; paste it manually to share."
  return table.concat(lines,"\n")
end
local function openReportDialog()
  if not reportFrame then
    reportFrame=CreateFrame("Frame","WacheonuiReportFrame",UIParent,"BackdropTemplate")
    reportFrame:SetSize(480,428)
    reportFrame:SetPoint("CENTER",UIParent,"CENTER",0,35)
    reportFrame:SetFrameStrata("DIALOG")
    reportFrame:SetMovable(true);reportFrame:EnableMouse(true)
    reportFrame:RegisterForDrag("LeftButton")
    reportFrame:SetScript("OnDragStart",reportFrame.StartMoving)
    reportFrame:SetScript("OnDragStop",reportFrame.StopMovingOrSizing)
    reportFrame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",edgeSize=28,insets={left=8,right=8,top=8,bottom=8}})
    local title=reportFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",0,-20);title:SetText(WCN_L("와천의 · 새로운 날씨 관측 및 제보"))
    local close=CreateFrame("Button",nil,reportFrame,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-5,-5)
    local help=reportFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    help:SetPoint("TOPLEFT",22,-48);help:SetText(WCN_L("화면에서 직접 관찰한 현상을 선택하세요 (API와 다를 수 있음)"))
    reportType="other"
    for i,item in ipairs(reportTypes) do
      local key,label=item[1],item[2]
      local btn=makeButton(reportFrame,label,20+((i-1)%3)*148,-72-math.floor((i-1)/3)*34,140,function()
        reportType=key
        if reportExport then reportExport:SetText("선택: "..label.." / 메모를 입력하고 저장하세요.") end
      end)
    end
    local noteLabel=reportFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    noteLabel:SetPoint("TOPLEFT",22,-147);noteLabel:SetText(WCN_L("현상 설명 (최대 80자)"))
    reportNote=CreateFrame("EditBox",nil,reportFrame,"InputBoxTemplate")
    reportNote:SetSize(420,26);reportNote:SetPoint("TOPLEFT",25,-170)
    reportNote:SetAutoFocus(false);reportNote:SetMaxLetters(80)
    reportNote:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
    makeButton(reportFrame,WCN_L("API 원본값 저장"),20,-211,140,function()
      execute("captureunknown")
      reportExport:SetText(reportText())
    end)
    makeButton(reportFrame,WCN_L("수동 제보 저장"),168,-211,140,function()
      local note=reportNote:GetText() or ""
      if Wacheonui_RunCommand then Wacheonui_RunCommand("report "..reportType.." "..note) end
      reportExport:SetText(reportText())
    end)
    makeButton(reportFrame,WCN_L("제보 내용 만들기"),316,-211,145,function()
      reportExport:SetText(reportText())
    end)
    local exportLabel=reportFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    exportLabel:SetPoint("TOPLEFT",22,-248);exportLabel:SetText(WCN_L("제보 내용 (Ctrl+A → Ctrl+C로 복사)"))
    reportExport=CreateFrame("EditBox",nil,reportFrame,"InputBoxTemplate")
    reportExport:SetMultiLine(true);reportExport:SetAutoFocus(false)
    reportExport:SetFontObject("ChatFontNormal")
    reportExport:SetSize(420,108);reportExport:SetPoint("TOPLEFT",25,-271)
    reportExport:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
    makeButton(reportFrame,WCN_L("전체 선택 / 복사 준비"),239,-386,220,function()
      reportExport:SetFocus();reportExport:HighlightText()
    end)
  end
  reportFrame:Show()
  reportExport:SetText(reportText())
end

local function init()
  if root then return end
  root=CreateFrame("Frame","WacheonuiSettingsFrame",UIParent,"BackdropTemplate")
  root:SetSize(540,485);root:SetPoint("CENTER");root:SetFrameStrata("DIALOG")
  root:SetMovable(true);root:EnableMouse(true);root:RegisterForDrag("LeftButton")
  root:SetScript("OnDragStart",root.StartMoving);root:SetScript("OnDragStop",root.StopMovingOrSizing)
  root:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",edgeSize=28,insets={left=8,right=8,top=8,bottom=8}})
  local title=root:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("TOP",0,-18);title:SetText(WCN_L("와천의 · 설정"))
  local close=CreateFrame("Button",nil,root,"UIPanelCloseButton");close:SetPoint("TOPRIGHT",-5,-5)
  local function run(x,y,name,cmd)
    makeButton(root,name,x,y,155,function() execute(cmd) end)
  end
  -- Primary actions: everyday weather observation and network synchronization.
  run(20,-50,WCN_L("관측 상태"),"status");run(185,-50,WCN_L("관측 기록"),"history");run(350,-50,WCN_L("지도 열기"),"map")
  run(20,-84,WCN_L("통신 상태"),"netstatus");run(185,-84,WCN_L("동기화 요청"),"sync")
  makeButton(root,WCN_L("통신 켜기/끄기"),350,-84,155,function()
    execute(db().netEnabled==false and "neton" or "netoff")
  end)
  makeButton(root,WCN_L("새 날씨 제보 / 복사"),20,-126,235,openReportDialog)
  makeButton(root,WCN_L("통신 진단 보기"),270,-126,235,function()
    showOutput(Wacheonui_GetDiagnostics and Wacheonui_GetDiagnostics() or WCN_L("진단 불가"))
  end)
  -- Developer-only commands (dbcheck, build, captureunknown, etc.) remain
  -- accessible through the existing slash-command handler, not the main UI.
  local sub=root:CreateFontString(nil,"OVERLAY","GameFontNormal")
  sub:SetPoint("TOPLEFT",20,-174);sub:SetText(WCN_L("지도 및 표시 설정"))
  addCheck(root,WCN_L("지도 날씨 표시"),20,-191,"mapEnabled",function() if Wacheonui_RefreshMap then Wacheonui_RefreshMap() end end)
  addCheck(root,WCN_L("지역 날씨 패널"),200,-191,"showCurrentWeather",function() if Wacheonui_RefreshMap then Wacheonui_RefreshMap() end end)
  local lock=CreateFrame("CheckButton",nil,root,"UICheckButtonTemplate")
  lock:SetPoint("TOPLEFT",380,-191);lock:SetSize(24,24);lock:SetChecked(db().panelLocked)
  local lockLabel=root:CreateFontString(nil,"OVERLAY","GameFontNormalSmall");lockLabel:SetPoint("LEFT",lock,"RIGHT",3,0);lockLabel:SetText(WCN_L("패널 잠금"))
  lock:SetScript("OnClick",function(self) db().panelLocked=self:GetChecked() and true or false end)
  makeButton(root,WCN_L("패널 크기 -"),20,-228,110,function()
    db().panelScale=math.max(0.7,(db().panelScale or 1)-0.1)
    if Wacheonui_SetPanelScale then Wacheonui_SetPanelScale(db().panelScale) end
  end)
  makeButton(root,WCN_L("패널 크기 +"),140,-228,110,function()
    db().panelScale=math.min(1.5,(db().panelScale or 1)+0.1)
    if Wacheonui_SetPanelScale then Wacheonui_SetPanelScale(db().panelScale) end
  end)
  makeButton(root,WCN_L("패널 위치 초기화"),270,-228,235,function() if Wacheonui_ResetPanel then Wacheonui_ResetPanel() end end)
  local alphaTitle=root:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  alphaTitle:SetPoint("TOPLEFT",20,-261);alphaTitle:SetText(WCN_L("패널 투명도:"))
  local alphaValue=root:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  alphaValue:SetPoint("TOPLEFT",455,-261)
  local slider=CreateFrame("Slider","WacheonuiPanelAlphaSlider",root,"OptionsSliderTemplate")
  slider:SetPoint("TOPLEFT",125,-259);slider:SetSize(295,16)
  slider:SetMinMaxValues(0.2,1);slider:SetValueStep(0.05)
  if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
  slider:SetValue(db().panelAlpha or 0.9)
  _G[slider:GetName().."Low"]:SetText("20%")
  _G[slider:GetName().."High"]:SetText("100%")
  _G[slider:GetName().."Text"]:SetText("")
  slider:SetScript("OnValueChanged",function(self,v)
    v=math.floor(v*20+0.5)/20
    db().panelAlpha=v
    alphaValue:SetText(math.floor(v*100+0.5).."%")
    if Wacheonui_SetPanelAlpha then Wacheonui_SetPanelAlpha(v) end
  end)
  alphaValue:SetText(math.floor((db().panelAlpha or 0.9)*100+0.5).."%")
  local label=root:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  label:SetPoint("TOPLEFT",20,-301);label:SetText(WCN_L("관측 유효시간:"))
  for i,v in ipairs({900,1800,3600}) do
    makeButton(root,({WCN_L("15분"),WCN_L("30분"),WCN_L("60분")})[i],115+(i-1)*105,-295,95,function()
      db().freshSeconds=v
      if Wacheonui_RefreshMap then Wacheonui_RefreshMap() end
      showOutput("관측 유효시간: "..(v/60).."분 적용")
    end)
  end
  local outTitle=root:CreateFontString(nil,"OVERLAY","GameFontNormal")
  outTitle:SetPoint("TOPLEFT",20,-337);outTitle:SetText(WCN_L("상태 및 진단 결과 (Ctrl+A, Ctrl+C)"))
  local edit=CreateFrame("EditBox",nil,root,"InputBoxTemplate")
  edit:SetMultiLine(true);edit:SetAutoFocus(false);edit:SetFontObject("ChatFontNormal")
  edit:SetSize(480,65);edit:SetPoint("TOPLEFT",root,"TOPLEFT",28,-364)
  edit:SetTextInsets(6,6,6,6);edit:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
  output=edit
  makeButton(root,WCN_L("전체 선택 / 복사 준비"),290,-433,215,function() output:SetFocus();output:HighlightText() end)
  showOutput(WCN_L("관측·통신 상태를 확인하거나 지도 표시를 설정하세요."))
  root:Hide()
end
Wacheonui_ToggleSettings=function()
  init();root:SetShown(not root:IsShown())
end
local function iconButton(name,texture,angle,fn)
  local b=CreateFrame("Button",name,Minimap)
  b:SetSize(32,32);b:SetFrameStrata("MEDIUM");b:SetFrameLevel(Minimap:GetFrameLevel()+5)
  local key=name=="WacheonuiWeatherButton" and "minimapWeather" or "minimapSettings"
  local function place(a)
    local radius=math.max(48,(Minimap:GetWidth() or 140)*0.5+10)
    b:ClearAllPoints()
    b:SetPoint("CENTER",Minimap,"CENTER",math.cos(a)*radius,math.sin(a)*radius)
  end
  local saved=db()[key]
  local a=(saved and saved.angle) or angle
  if saved and not saved.angle and saved.x and saved.y then a=math.atan2(saved.y,saved.x) end
  place(a)
  local bg=b:CreateTexture(nil,"BACKGROUND")
  bg:SetAllPoints();bg:SetTexture("Interface\\AddOns\\Wacheonui\\Icons\\MinimapRing")
  local t=b:CreateTexture(nil,"ARTWORK")
  t:SetPoint("CENTER");t:SetSize(21,21);t:SetTexture(texture)
  -- Circular crop keeps the weather/logo inside the gilded ring.
  if t.SetMask then
    local mask=b:CreateMaskTexture()
    mask:SetTexture("Interface\\AddOns\\Wacheonui\\Icons\\MinimapMask","CLAMPTOBLACKADDITIVE","CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(t);t:AddMaskTexture(mask)
  end
  b.icon=t;b:SetScript("OnClick",fn)
  b:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_LEFT")
    GameTooltip:AddLine(name=="WacheonuiWeatherButton" and WCN_L("와천의 · 현재 날씨") or WCN_L("와천의 · 설정"))
    if name=="WacheonuiWeatherButton" then
      local zone=GetZoneText and GetZoneText() or WCN_L("지역 미확인")
      GameTooltip:AddLine(zone,1,1,1)
      local best
      if type(Wacheonui_SelectWeather)=="function" then
        best=Wacheonui_SelectWeather(zone)
      end
      GameTooltip:AddLine(best and ("날씨 type="..best.kind.." / "..math.floor((time()-best.at)/60)..WCN_L("분 전")) or WCN_L("미관측"),0.8,0.9,0.8)
    else GameTooltip:AddLine(WCN_L("클릭: 설정창 / 드래그: 위치 조절"),1,1,1) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave",function() GameTooltip:Hide() end)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart",function(self)
    self.dragging=true
    self:SetScript("OnUpdate",function(button)
      local x,y=GetCursorPosition()
      local scale=UIParent:GetEffectiveScale()
      local mx,my=Minimap:GetCenter()
      if x and mx and scale and scale>0 then
        local ang=math.atan2(y/scale-my,x/scale-mx)
        db()[key]={angle=ang}
        place(ang)
      end
    end)
  end)
  b:SetScript("OnDragStop",function(self)
    self.dragging=false;self:SetScript("OnUpdate",nil)
  end)
  return b
end
-- Weather badges follow the actual game clock frame rather than minimap coordinates.
-- The clock is never replaced; the existing sun/moon remains visible.
-- WoW Forever's visible moon button is not GameTimeFrame (calendar).
-- Prefer a verified clock frame only; otherwise position relative to Minimap.
-- Relative placement is configurable because UI addons can relocate the clock.
local function clockButton()
  -- WoW Forever: the third direct child of MinimapContainer was verified
  -- in-game with a red overlay on the actual 42x42 day/night dial.
  -- Child order is only a hint: verify dimensions and position every time.
  local cluster=MinimapCluster
  local container=cluster and cluster.MinimapContainer
  if not container or not container.GetChildren then return nil end
  local function valid(f)
    if not f or not f.GetWidth or not f.GetCenter or not f.IsShown then return false end
    if not f:IsShown() then return false end
    local w,h=f:GetWidth(),f:GetHeight()
    if not w or not h or w<34 or w>54 or h<34 or h>54 then return false end
    local x,y=f:GetCenter()
    local cx,cy=container:GetCenter()
    if not x or not y or not cx or not cy then return false end
    -- Dial sits near the upper-right of the minimap container.
    return x>cx and y>cy
  end
  local candidate=select(3,container:GetChildren())
  if valid(candidate) then return candidate end
  -- Fail closed rather than anchoring to an unrelated minimap element.
  return nil
end
local function worldMapVisible()
  return WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown()
end
local function ensureOverlay(anchor)
  if not anchor then return false end
  if not minimapOverlay then
    minimapOverlay=CreateFrame("Frame",nil,UIParent)
    minimapOverlay:EnableMouse(false)
    minimapOverlay.icon=minimapOverlay:CreateTexture(nil,"OVERLAY",nil,7)
  end
  if overlayAnchor~=anchor then
    minimapOverlay:SetParent(UIParent)
    overlayAnchor=anchor
  end
  minimapOverlay:ClearAllPoints()
  -- Anchor to the verified 42x42 dial, never to estimated Minimap offsets.
  minimapOverlay:SetSize(42,42)
  minimapOverlay:SetPoint("CENTER",anchor,"CENTER",0,0)
  minimapOverlay:SetFrameStrata("TOOLTIP")
  minimapOverlay:SetFrameLevel(100)
  -- Let cloud artwork extend slightly past the clock dial. Precipitation has its own clipped holder.
  if minimapOverlay.SetClipsChildren then minimapOverlay:SetClipsChildren(false) end
  local t=minimapOverlay.icon
  t:ClearAllPoints()
  t:SetSize(26,26)
  t:SetPoint("CENTER",minimapOverlay,"CENTER",0,0)
  minimapOverlay:Show()
  return true
end
-- Small independent weather particles. No animation of the whole weather icon.
-- The clock artwork remains untouched; only precipitation is animated.
local function ensureParticles()
  if minimapOverlay.particles then return end
  local holder=CreateFrame("Frame",nil,minimapOverlay)
  -- All particles stay in the clock dial interior, below the cloud.
  holder:SetSize(28,19)
  holder:SetPoint("CENTER",minimapOverlay,"CENTER",0,-5)
  holder:EnableMouse(false)
  if holder.SetClipsChildren then holder:SetClipsChildren(true) end
  minimapOverlay.particleHolder=holder
  minimapOverlay.particles={}
  for i=1,5 do
    local tex=holder:CreateTexture(nil,"OVERLAY",nil,7)
    tex:SetColorTexture(0.42,0.81,1,0.95)
    tex:SetSize(1.5,5)
    tex:Hide()
    minimapOverlay.particles[i]={region=tex,phase=(i-1)/5,x=((i*9)%21)-10,speed=0.65+(i%3)*0.18}
  end
  holder.elapsed=0
  holder:SetScript("OnUpdate",function(self,dt)
    if not self:IsShown() or not self.kind then return end
    self.elapsed=self.elapsed+math.min(dt,0.1)
    if self.elapsed<0.03 then return end
    local step=self.elapsed;self.elapsed=0
    for i,p in ipairs(minimapOverlay.particles) do
      p.phase=(p.phase+step*p.speed)%1
      local y=7.5-15*p.phase
      local x=p.x+(self.kind==2 and math.sin(p.phase*6.283+i)*1.7 or 0)
      p.region:ClearAllPoints()
      p.region:SetPoint("CENTER",self,"CENTER",x,y)
      -- Fade near both ends of the path, avoiding particles sticking to the rim.
      local fade=math.min(1,p.phase*7,(1-p.phase)*7)
      p.region:SetAlpha(math.max(0,fade))
    end
  end)
  holder:Hide()
end
local function configureWeatherAnimation(kind,alpha)
  if not minimapOverlay then return end
  ensureParticles()
  local holder=minimapOverlay.particleHolder
  local wanted=(db().minimapWeatherAnimation==false) and nil or kind
  if wanted~=1 and wanted~=2 then
    holder.kind=nil;holder:Hide()
    for _,p in ipairs(minimapOverlay.particles) do p.region:Hide() end
    return
  end
  holder.kind=wanted
  holder:SetAlpha(alpha or 1)
  for _,p in ipairs(minimapOverlay.particles) do
    if wanted==1 then
      p.region:SetColorTexture(0.38,0.76,1,1)
      p.region:SetSize(2,6.5)
    else
      p.region:SetColorTexture(0.91,0.97,1,1)
      p.region:SetSize(3.2,3.2)
    end
    p.region:Show()
  end
  holder:Show()
end
SLASH_WACHEONUIANIM1="/wcnanim"
SlashCmdList["WACHEONUIANIM"]=function(msg)
  msg=(msg or ""):lower():match("^%s*(.-)%s*$")
  if msg=="on" then db().minimapWeatherAnimation=true
  elseif msg=="off" then db().minimapWeatherAnimation=false
  else print("[와천의] /wcnanim on | off");return end
  -- UpdateMini is declared earlier in this file.
  updateMini()
  print("[와천의] 미니맵 날씨 애니메이션: "..msg)
end
-- Allow users of custom minimaps to calibrate the overlay without editing Lua.
SLASH_WACHEONUICLOCKPOS1="/wcnclockpos"
SlashCmdList["WACHEONUICLOCKPOS"]=function(msg)
  local x,y=(msg or ""):match("^%s*(-?%d+)%s+(-?%d+)%s*$")
  if not x then
    print("[와천의] /wcnclockpos X Y (예: -24 -9) | /wcnclockpos reset")
    if (msg or ""):match("reset") then db().clockOffsetX=nil;db().clockOffsetY=nil;updateMini() end
    return
  end
  db().clockOffsetX=math.max(-100,math.min(100,tonumber(x)))
  db().clockOffsetY=math.max(-100,math.min(100,tonumber(y)))
  updateMini()
end
local function ensureFallback()
  if not minimapWeather then
    minimapWeather=iconButton("WacheonuiWeatherButton","Interface\\AddOns\\Wacheonui\\Icons\\Unobserved",0.9,Wacheonui_ToggleSettings)
  end
  return minimapWeather
end
updateMini = function()
  local mode=db().minimapWeatherMode or "auto"
  local mapOpen=worldMapVisible()
  local anchor=mapOpen and nil or clockButton()
  local useClock=(mode~="off" and mode~="independent" and anchor~=nil)
  local useFallback=(mode=="independent")
  if minimapOverlay then
    if minimapOverlay.particleHolder then
      minimapOverlay.particleHolder.kind=nil
      minimapOverlay.particleHolder:Hide()
    end
    minimapOverlay:Hide()
  end
  if minimapWeather then minimapWeather:Hide() end
  -- Suppress minimap weather visuals while any world/continent/zone map is open.
  if mode=="off" or mapOpen then return end
  local zone=type(Wacheonui_WeatherZoneKey)=="function" and Wacheonui_WeatherZoneKey(GetZoneText and GetZoneText() or "",GetSubZoneText and GetSubZoneText() or "") or (GetZoneText and GetZoneText() or "")
  local best,conflict
  if type(Wacheonui_SelectWeather)=="function" then
    best,conflict=Wacheonui_SelectWeather(zone)
  end
  local path="Interface\\AddOns\\Wacheonui\\Icons\\"
  local icons={[1]="Rain",[2]="Snow",[3]="Storm"}
  local file=path..(best and (icons[best.kind] or "Unobserved") or "Unobserved")
  if useClock and ensureOverlay(anchor) then
    -- No extra moon/sun in clear weather; the game's clock is already correct.
    -- With animated precipitation, show the cloud artwork and move only the drops/flakes.
    -- Avoid displaying static precipitation and animated precipitation twice.
    local animated=(db().minimapWeatherAnimation~=false and best and (best.kind==1 or best.kind==2))
    minimapOverlay.icon:SetTexture(animated and (path.."CloudPuffy") or file)
    minimapOverlay.icon:SetShown(best ~= nil and best.kind ~= 0)
    minimapOverlay.icon:ClearAllPoints()
    if animated then
      -- Cloud occupies the upper third; precipitation moves below it.
      minimapOverlay.icon:SetSize(30,23)
      minimapOverlay.icon:SetPoint("TOP",minimapOverlay,"TOP",0,6)
    else
      minimapOverlay.icon:SetSize(best and best.kind==3 and 31 or 28,best and best.kind==3 and 31 or 28)
      minimapOverlay.icon:SetPoint("CENTER",minimapOverlay,"CENTER",0,2)
    end
    if best and type(best.at)=="number" then
      local age=math.max(0,time()-best.at)
      local alpha=age<=1800 and 1 or age<=7200 and 0.9 or age<=21600 and 0.8 or age<=86400 and 0.7 or 0.6
      minimapOverlay.icon:SetAlpha(alpha)
    else
      minimapOverlay.icon:SetAlpha(1)
    end
    if best and (best.kind==1 or best.kind==2) then
      configureWeatherAnimation(best.kind,minimapOverlay.icon:GetAlpha())
    else
      configureWeatherAnimation(nil)
    end
    -- Storm: brief lightning flashes, without shifting the clock artwork.
    minimapOverlay.stormFlash=(best and best.kind==3 and db().minimapWeatherAnimation~=false) or false
    minimapOverlay.baseAlpha=minimapOverlay.icon:GetAlpha()
    if minimapOverlay.stormFlash then
      minimapOverlay.flashElapsed=0
      minimapOverlay:SetScript("OnUpdate",function(self,dt)
        self.flashElapsed=(self.flashElapsed+math.min(dt,0.1))%2.8
        local t=self.flashElapsed
        local flash=(t<0.10 or (t>0.19 and t<0.28)) and 1 or 0.62
        self.icon:SetAlpha((self.baseAlpha or 1)*flash)
      end)
    else
      minimapOverlay:SetScript("OnUpdate",nil)
    end
  elseif useFallback then
    local b=ensureFallback()
    b.icon:SetTexture(best and best.kind==0 and (path.."Sun") or file)
    b:Show()
  end
end
SLASH_WACHEONUICLOCK1="/wcnclock"
SlashCmdList["WACHEONUICLOCK"]=function(msg)
  msg=(msg or ""):lower():match("^%s*(.-)%s*$")
  if msg~="auto" and msg~="clock" and msg~="independent" and msg~="off" then
    print("[와천의] /wcnclock auto | clock | independent | off")
    return
  end
  db().minimapWeatherMode=msg
  updateMini()
  print("[와천의] 미니맵 날씨 표시: "..msg)
end
local startup=CreateFrame("Frame")
startup:RegisterEvent("PLAYER_LOGIN")
startup:SetScript("OnEvent",function()
  minimapSettings=iconButton("WacheonuiSettingsButton","Interface\\AddOns\\Wacheonui\\Icons\\WacheonuiLogo64",2.6,Wacheonui_ToggleSettings)
  -- The weather indicator now shares Blizzard's existing clock button.
  -- The settings icon remains freely draggable around the minimap edge.
  local elapsed=0
  startup:SetScript("OnUpdate",function(_,dt)
    elapsed=elapsed+dt
    if elapsed>=3 then elapsed=0;updateMini() end
  end)
  -- React immediately to map open/close, including zone and continent views.
  if WorldMapFrame then
    WorldMapFrame:HookScript("OnShow",function() updateMini() end)
    WorldMapFrame:HookScript("OnHide",function() updateMini() end)
  end
  updateMini()
end)
