-- Wacheonui v0.7.7 | Forever launch-build compatibility diagnostics; gameplay verification pending
-- Commands: /wcn help | add NAME | remove NAME | peers | status | log | send | debug
local CLUB_NAME = "Wacheonui"
local STREAM_NAME = "기상 관측 데이터"
local CLUB_FALLBACK_ID = 23178961
local STREAM_FALLBACK_ID = 2
local clubId, streamId, lastMessageId = nil, nil, nil
local pendingConfirm, lastPayload = nil, nil
local sequence = 0
local lastPollDigest = nil
local lastPollCount = nil
local lastPosted = nil
local processedIds = {}
local pollElapsed, discoverElapsed, lastClubSendAt = 0, 0, 0
local POLL_SECONDS, DISCOVER_SECONDS, SEND_COOLDOWN = 8, 30, 10
local MAX_LOG = 500
local FRESH_SECONDS = 1800
-- Runtime validity is adjustable from the settings UI.
local ADDON_PREFIX = "WCN7"
-- v0.7.6 sync uses the existing registered addon prefix.
local SYNC_COOLDOWN = 60
local SYNC_MAX_PER_RESPONSE = 24
local syncLastRequest, syncPending, syncRosterKey = 0, nil, nil
local syncRequests, syncSent, syncReceived = 0, 0, 0
local syncNonce = 0
local syncOutstanding = {} -- only accept snapshots for our recent requests
local netLastSent, netLastSig, netElapsed = 0, nil, 0
local netReceived, netSent = 0, 0
local netEnabled = false
local MAX_REPORTS = 100
local KNOWN_TYPES = {[0]=true,[1]=true,[2]=true}
local REPORT_TYPES = {thunder="천둥", lightning="번개", wind="강풍·돌풍", fog="안개", other="기타"}
local f = CreateFrame("Frame")
local db, myName, myRealm
local function freshSeconds() return (db and tonumber(db.freshSeconds)) or FRESH_SECONDS end
local ready, lastSignature = false, nil
local lastSendAt = 0
local pendingReason = nil
local queuedPayload, queuedZone = nil, nil
local lastQueuedSignature = nil
local debugMode = false
local lastUnknownAlert = {}
local function refreshMap()
  if type(Wacheonui_RefreshMap) == "function" then Wacheonui_RefreshMap() end
end

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff65cdb9[와천의]|r " .. tostring(msg))
end

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

local function normalizeName(s)
  s = trim(s)
  if s == "" then return nil end
  if not s:find("-", 1, true) and myRealm and myRealm ~= "" then
    -- A bare character name is accepted on the current realm.
    return s
  end
  return s
end

local function sameCharacter(a, b)
  if not a or not b then return false end
  local an = a:match("^([^-]+)")
  local bn = b:match("^([^-]+)")
  return an and bn and an:lower() == bn:lower()
end

-- Prefer the original API but probe the alternate API if available.
-- Neither API name nor response schema is assumed valid on KR 70707.
local function weather()
  local api = C_Weather
  if type(api) ~= "table" then return nil, "C_Weather unavailable" end
  local errors = {}
  for _, name in ipairs({"GetCurrentWeather", "GetWeather"}) do
    local fn = api[name]
    if type(fn) == "function" then
      local ok, value = pcall(fn)
      if ok and type(value) == "table" then
        local kind = tonumber(value.type)
        local intensity = tonumber(value.intensity)
        if kind and intensity then
          return {kind=kind, intensity=intensity}
        end
        errors[#errors+1] = name .. ": type/intensity missing"
      else
        errors[#errors+1] = name .. (ok and ": non-table response" or ": call failed")
      end
    else
      errors[#errors+1] = name .. ": unavailable"
    end
  end
  return nil, table.concat(errors, "; ")
end

-- Dalaran (Eastern Kingdoms) is a separate observation area even when the
-- client reports Hillsbrad/Alterac as the parent zone. Never remap Northrend.
local DALARAN_NAMES = { ["달라란"]=true, ["달라란 폐허"]=true, ["Dalaran"]=true, ["Dalaran Crater"]=true, ["Ruins of Dalaran"]=true }
local PARENT_NAMES = { ["힐스브래드 구릉지"]=true, ["힐스브라드 구릉지"]=true, ["알터렉 산맥"]=true, ["Hillsbrad Foothills"]=true, ["Alterac Mountains"]=true }
Wacheonui_WeatherZoneKey = function(zone, subzone)
  if type(zone)~="string" then return zone end
  if DALARAN_NAMES[zone] then return "달라란" end
  if PARENT_NAMES[zone] and DALARAN_NAMES[subzone] then return "달라란" end
  return zone
end
-- Only outdoor world observations are meaningful. Instance chat reception remains enabled.
local function canObserveOutdoors()
  if type(IsInInstance) ~= "function" then return true end
  local ok, inside, instanceType = pcall(IsInInstance)
  if not ok then return false end -- fail closed if the instance state is unreadable
  if not inside then return true end
  return instanceType ~= "party" and instanceType ~= "raid" and
         instanceType ~= "pvp" and instanceType ~= "arena" and
         instanceType ~= "scenario" and instanceType ~= "none"
end
local function resetOutdoorObservation()
  lastSignature=nil
  pendingReason=nil
  queuedPayload=nil
  queuedZone=nil
  lastQueuedSignature=nil
end
local function zoneInfo()
  local zone = (GetZoneText and GetZoneText()) or ""
  local subzone = (GetSubZoneText and GetSubZoneText()) or ""
  if zone == "" then return nil end
  return Wacheonui_WeatherZoneKey(zone, subzone), subzone
end

-- NWB v3.49 reference: Creature GUID field 5 is zoneUID (NOT field 3).
-- NWB explicitly disables its layer mapper on Forever. Therefore this is an
-- UNVERIFIED zone-scoped GUID fingerprint, never an authoritative layer ID.
local layerRaw, layerSeenAt, layerZone = nil, 0, nil
local LAYER_TTL = 120
local function currentLayer()
  if not canObserveOutdoors() then return nil end
  if not layerRaw or time()-layerSeenAt>LAYER_TTL then return nil end
  local zone = Wacheonui_WeatherZoneKey(GetZoneText and GetZoneText() or "", GetSubZoneText and GetSubZoneText() or "")
  if zone ~= layerZone then return nil end
  return layerRaw
end
local function sampleLayer(unit)
  if not canObserveOutdoors() or not UnitGUID then return end
  local okGuid,guid=pcall(UnitGUID,unit)
  if not okGuid then return end
  if issecretvalue and issecretvalue(guid) then return end
  local okParse,typ,zoneUID=pcall(function()
    if type(guid)~="string" then return nil end
    local a,b,c,d,e=guid:match("^([^-]+)%-([^-]+)%-([^-]+)%-([^-]+)%-([^-]+)%-")
    return a,e
  end)
  if not okParse or (typ~="Creature" and typ~="Vehicle") then return end
  if not zoneUID or not zoneUID:match("^%d+$") then return end
  local n=tonumber(zoneUID)
  if not n or n<=0 then return end
  local zone=Wacheonui_WeatherZoneKey(GetZoneText and GetZoneText() or "",GetSubZoneText and GetSubZoneText() or "")
  if not zone or zone=="" then return end
  local old=currentLayer()
  -- Z prefix distinguishes new zoneUID fingerprints from legacy instance IDs.
  layerRaw,layerSeenAt,layerZone="Z"..tostring(n),time(),zone
  if old and old~=layerRaw then lastSignature=nil end
end
Wacheonui_GetLayerRaw=function() return currentLayer() end
local function sameLayer(a,b)
  -- An unknown layer must not be treated as a match with a known layer.
  return a and b and a==b
end
-- Layer/phase identity is not exposed reliably. Treat contradictory remote weather
-- as ambiguous rather than pretending that the newest report is authoritative.
local CONFLICT_WINDOW = 180
local function conflictFor(zone)
  if not db or not db.log or not zone or zone=="" then return false end
  local now=time()
  local recent={}
  for i=#db.log,1,-1 do
    local r=db.log[i]
    if Wacheonui_WeatherZoneKey(r.zone,r.subzone)==zone and type(r.at)=="number" and r.at<=now+30 and now-r.at<=freshSeconds() then
      recent[#recent+1]=r
    end
  end
  for i=1,#recent do
    for j=i+1,#recent do
      local a,b=recent[i],recent[j]
      if a.observer~=b.observer and sameLayer(a.layer,b.layer) and math.abs(a.at-b.at)<=CONFLICT_WINDOW and a.kind~=b.kind then
        return true,a,b
      end
    end
  end
  return false
end
Wacheonui_WeatherConflict = function(zone) return conflictFor(zone) end
-- Preserve the last known report even after its freshness window ends.
-- Layer matching is preferred; an unknown/mismatched layer is only a labeled fallback.
Wacheonui_SelectWeather = function(zone)
  if not db or not zone or zone=="" then return nil,false end
  local now=time()
  local layer=currentLayer()
  local current=Wacheonui_WeatherZoneKey(GetZoneText and GetZoneText() or "", GetSubZoneText and GetSubZoneText() or "")
  local best, bestScore, localBest
  local function consider(r)
    if type(r)~="table" or type(r.at)~="number" or r.at>now+30 or
       Wacheonui_WeatherZoneKey(r.zone,r.subzone)~=zone then return end
    local score=0
    -- A known fingerprint is only a tentative partition, not a verified phase.
    -- Never promote a different fingerprint to the current phase's weather.
    if zone==current and layer and r.layer and r.layer~=layer then return end
    if layer and r.layer==layer then score=3
    elseif not layer and not r.layer then score=2
    elseif not r.layer then score=1
    else score=0 end
    if not best or score>bestScore or (score==bestScore and r.at>best.at) then
      best,bestScore=r,score
    end
    if zone==current and r.source=="local" and r.observer==myName and
       (not localBest or r.at>localBest.at) then localBest=r end
  end
  -- Persisted cache survives the rolling 500-entry diagnostic history.
  if db.lastKnown then
    for _,r in pairs(db.lastKnown) do consider(r) end
  end
  for _,r in ipairs(db.log or {}) do consider(r) end
  if localBest and now-localBest.at<=freshSeconds() and
     (not layer or not localBest.layer or localBest.layer==layer) then
    return localBest,conflictFor(zone)
  end
  local conflict=conflictFor(zone)
  -- A conflict affects confidence, not whether the last-known icon is displayed.
  return best,conflict
end
local function addRecord(observer, zone, subzone, kind, intensity, stamp, source, layer)
  zone = Wacheonui_WeatherZoneKey(zone, subzone)
  db.log[#db.log+1] = {
    observer=observer, zone=zone, subzone=subzone,
    kind=kind, intensity=intensity, at=stamp, source=source, layer=layer
  }
  while #db.log > MAX_LOG do table.remove(db.log, 1) end
  db.latest[observer .. "@" .. zone .. "@" .. tostring(layer or "?")] = db.log[#db.log]
  db.lastKnown=db.lastKnown or {}
  local cacheKey=zone .. "|" .. tostring(layer or "?")
  local previous=db.lastKnown[cacheKey]
  if not previous or (type(previous.at)=="number" and stamp>=previous.at) then
    db.lastKnown[cacheKey]=db.log[#db.log]
  end
  local conflict=conflictFor(zone)
  db.weatherConflicts=db.weatherConflicts or {}
  if conflict then db.weatherConflicts[zone]=time() else db.weatherConflicts[zone]=nil end
  if not KNOWN_TYPES[kind] then
    local key = tostring(kind)
    local last = lastUnknownAlert[key] or 0
    if debugMode and time() - last >= 300 then
      lastUnknownAlert[key] = time()
      say("미확인 기상 유형 발견! type=" .. tostring(kind) .. " / " .. zone .. " (" .. source .. ") /wcn history")
    end
    db.discoveries[key] = db.discoveries[key] or {first=stamp, zone=zone, observer=observer}
    db.discoveries[key].last = stamp
  end
  refreshMap()
end

-- Protocol: W1|unix_timestamp|weather_type|intensity|zone|subzone
-- Zone strings are validated and sanitized; no code is evaluated from messages.
local function cleanField(s)
  return tostring(s or ""):gsub("[|\r\n]", " "):sub(1, 80)
end

-- C_Club may return secret club/stream names in restricted contexts.
-- Never compare or stringify secret values; community discovery is optional.
local function safeClubNameEquals(value, expected)
  if issecretvalue and issecretvalue(value) then return false end
  local ok, equal = pcall(function()
    return type(value) == "string" and value == expected
  end)
  return ok and equal == true
end

local function findCommunity()
  clubId, streamId = nil, nil
  if not C_Club or type(C_Club.GetSubscribedClubs) ~= "function" or type(C_Club.GetStreams) ~= "function" then return false end
  local ok, clubs = pcall(C_Club.GetSubscribedClubs)
  if not ok or type(clubs) ~= "table" then return false end
  for _, c in ipairs(clubs) do
    -- Wrap access too: some fields may be protected even when the table is public.
    local goodClub, cid = pcall(function()
      if type(c) ~= "table" or not safeClubNameEquals(c.name, CLUB_NAME) then return nil end
      if issecretvalue and issecretvalue(c.clubId) then return nil end
      return c.clubId
    end)
    if goodClub and cid then
      local good, streams = pcall(C_Club.GetStreams, cid)
      if good and type(streams) == "table" then
        for _, st in ipairs(streams) do
          local goodStream, sid = pcall(function()
            if type(st) ~= "table" or not safeClubNameEquals(st.name, STREAM_NAME) then return nil end
            if issecretvalue and issecretvalue(st.streamId) then return nil end
            return st.streamId
          end)
          if goodStream and sid then clubId, streamId = cid, sid; return true end
        end
      end
    end
  end
  return false
end

local function sendCommunity(payload, force)
  if not db.shareEnabled then return false, "공유 OFF" end
  if not clubId or not streamId then return false, "커뮤니티 미연결" end
  if not C_Club or type(C_Club.SendMessage) ~= "function" then return false, "SendMessage 없음" end
  if not force and time() - lastClubSendAt < SEND_COOLDOWN then return false, "전송 간격 제한" end
  -- Use the exact direct API invocation validated in-game; pcall only captures Lua errors.
  local ok, result = pcall(C_Club.SendMessage, clubId, streamId, payload)
  if not ok then return false, "API 오류: " .. tostring(result) end
  lastClubSendAt = time()
  pendingConfirm = {payload=payload, at=time(), lastNotice=0}
  lastPayload = payload
  say("직접 송신 API 호출 완료 (게시 확인 대기): " .. payload:sub(1,130))
  return true, "API 호출 완료 / 게시 확인 대기"
end

local function parseCommunityMessage(info)
  if type(info) ~= "table" or type(info.content) ~= "string" then return end
  local stamp, kind, intensity, zone, subzone = info.content:match("^WCN2|(%d+)|([%-]?%d+)|([%d%.%-]+)|([^|]+)|([^|]*)")
  stamp, kind, intensity = tonumber(stamp), tonumber(kind), tonumber(intensity)
  if not stamp or not kind or not intensity or not zone or #zone > 80 or #subzone > 80 then return end
  if stamp < 0 or stamp > time()+300 or stamp < time()-86400 then return end
  local observer = tostring(info.author and (info.author.name or info.author.guid) or info.authorName or "커뮤니티 관측자")
  local key = table.concat({observer,stamp,zone,kind,intensity}, "|")
  if db.seen[key] then return end
  db.seen[key] = true
  local n=0
  for _ in pairs(db.seen) do n=n+1 end
  if n > 500 then db.seen = {[key]=true} end
  addRecord(observer, zone, subzone, kind, intensity, stamp, "community")
  if debugMode then say("커뮤니티 수신: " .. zone .. " / type=" .. kind .. " / 익명") end
end

-- Message IDs are opaque tables on this client. Never compare or stringify
-- their table addresses to determine order.
local function pollCommunity()
  if not db or not db.shareEnabled or not clubId or not streamId then return end
  if type(C_Club.GetMessageRanges) ~= "function" or type(C_Club.GetMessageInfo) ~= "function" then return end
  local ok, ranges = pcall(C_Club.GetMessageRanges, clubId, streamId)
  if not ok or type(ranges) ~= "table" or #ranges == 0 then return end
  local r = ranges[#ranges]
  if type(r.newestMessageId) ~= "table" then return end
  local messages = {}
  local good, newest = pcall(C_Club.GetMessageInfo, clubId, streamId, r.newestMessageId)
  if good and type(newest) == "table" then messages[#messages+1] = newest end
  if type(C_Club.GetMessagesInRange) == "function" then
    local yes, data = pcall(C_Club.GetMessagesInRange, clubId, streamId, r.oldestMessageId, r.newestMessageId)
    if yes and type(data) == "table" then
      for _, item in ipairs(data) do
        if type(item) == "table" then
          -- Some client builds return message IDs rather than full message info.
          if type(item.content) ~= "string" and item.messageId then
            local fine, info = pcall(C_Club.GetMessageInfo, clubId, streamId, item.messageId)
            if fine then item = info end
          end
          messages[#messages+1] = item
        end
      end
    end
  end
  local n, newestContent = 0, nil
  for _, info in ipairs(messages) do
    if type(info) == "table" and type(info.content) == "string" then
      n = n + 1
      newestContent = info.content
      -- Confirmation checks the unique nonce-bearing payload, not just the timestamp.
      if pendingConfirm and info.content == pendingConfirm.payload then
        lastPosted = time()
        say("커뮤니티 게시 확인: " .. info.content:sub(1,110))
        pendingConfirm = nil
      end
      local author = info.author and (info.author.name or info.author.guid) or info.authorName or ""
      local key = tostring(author) .. "|" .. info.content
      if not processedIds[key] then
        processedIds[key] = time()
        parseCommunityMessage(info)
      end
    end
  end
  for key, at in pairs(processedIds) do
    if time() - at > 1800 then processedIds[key] = nil end
  end
  -- Debug only on a change, never spam the same snapshot every 8 seconds.
  local digest = tostring(n) .. "|" .. tostring(newestContent)
  if debugMode and digest ~= lastPollDigest then
    say("커뮤니티 조회: " .. n .. "건 / 최신: " .. tostring(newestContent or "없음"):sub(1,85))
  end
  lastPollDigest = digest
  if pendingConfirm and time() - pendingConfirm.at >= 30 then
    say("커뮤니티 게시 미확인(30초). 실제 게시 여부 불명: /wcn payload")
    pendingConfirm = nil
  end
end

-- Observe locally on events. Queue the newest observation; do not attempt to
-- send from OnEvent/OnUpdate because direct command succeeded but deferred failed.
local function publish(reason, force)
  if not canObserveOutdoors() then return end
  if not ready or not db then return end
  local zone, subzone = zoneInfo()
  if not zone then return end
  local w, err = weather()
  if not w then
    if debugMode then say("관측 실패: " .. tostring(err)) end
    return
  end
  local sig = zone .. "|" .. subzone .. "|" .. w.kind .. "|" .. w.intensity .. "|" .. (currentLayer() or "?")
  if not force and sig == lastSignature then return end
  local now = time()
  if not force and now - lastSendAt < 3 then
    pendingReason = reason
    return
  end
  pendingReason = nil
  lastSignature, lastSendAt = sig, now
  addRecord(myName, zone, subzone, w.kind, w.intensity, now, "local", currentLayer())
  if db.shareEnabled and clubId and streamId then
    sequence = sequence + 1
    local nonce = tostring(now) .. "-" .. tostring(sequence) .. "-" .. tostring(math.floor(GetTime()*1000) % 1000000)
    queuedPayload = "WCN2|" .. table.concat({now,w.kind,w.intensity,cleanField(zone),cleanField(subzone),nonce}, "|")
    queuedZone = zone
    lastQueuedSignature = sig
    if debugMode then say("관측 대기: " .. zone .. " (전송하려면 /wcn send)") end
  end
  if debugMode then
    say(string.format("관측 [%s] %s / type=%s intensity=%s / 커뮤니티: %s", reason, zone, w.kind, w.intensity, db.shareEnabled and "수동 전송 대기" or "공유 OFF"))
  end
end

local function sendQueuedFromCommand()
  if not canObserveOutdoors() then say("인스턴스에서는 날씨 관측 전송이 중단됩니다."); return end
  if not db.shareEnabled then say("공유 OFF: /wcn share on"); return end
  if not clubId or not streamId then findCommunity() end
  if not clubId or not streamId then say("커뮤니티 미연결: /wcn network"); return end
  -- Mirror the successful testdirect call as closely as possible.
  -- Do not call publish() or any other observation function before sending.
  -- Keep the queued payload if posting is not independently verified.
  if not queuedPayload then
    say("대기 관측 없음: 지역 이동 또는 날씨 변화 후 다시 시도하세요")
    return
  end
  local payload = queuedPayload
  local ok, result = pcall(C_Club.SendMessage, clubId, streamId, payload)
  say("진단 직접 호출: " .. payload .. " / pcall=" .. tostring(ok) .. " / 반환=" .. tostring(result))
  if ok then
    lastPayload = payload
    pendingConfirm = {payload=payload, at=time(), lastNotice=0}
    say("API 호출됨. 실제 게시 여부는 커뮤니티 채팅방에서 확인하세요.")
  else
    say("API 오류: " .. tostring(result))
  end
end

-- Diagnostic: compare a direct API call from a slash command with one
-- deferred to OnUpdate. Neither pcall success nor nil return proves posting.
local diagnosticDeferred = nil
local function diagnosticSend(mode)
  if not clubId or not streamId then say("진단: 커뮤니티 미연결"); return end
  if not C_Club or type(C_Club.SendMessage) ~= "function" then say("진단: 전송 API 없음"); return end
  sequence = sequence + 1
  local payload = "WCN-DIAG-" .. mode .. "-" .. tostring(time()) .. "-" .. tostring(sequence)
  if mode == "deferred" then
    diagnosticDeferred = payload
    say("진단 예약: " .. payload .. " (다음 프레임에서 호출)")
    return
  end
  local ok, result = pcall(C_Club.SendMessage, clubId, streamId, payload)
  say("진단 직접 호출: " .. payload .. " / pcall=" .. tostring(ok) .. " / 반환=" .. tostring(result))
  say("실제 게시 여부는 커뮤니티 채팅방에서 확인해 주세요.")
end

-- v0.6.7: isolate content/length from the slash-command execution context.
-- These calls are synchronous, never queued to OnUpdate.
local function diagnosticPayload(mode)
  if not clubId or not streamId then findCommunity() end
  if not clubId or not streamId then say("진단: 커뮤니티 미연결"); return end
  if not C_Club or type(C_Club.SendMessage) ~= "function" then say("진단: 전송 API 없음"); return end
  sequence = sequence + 1
  local nonce = tostring(time()) .. "-" .. tostring(sequence)
  local payload
  if mode == "ascii" then
    payload = "WCN2|" .. tostring(time()) .. "|0|0|TESTZONE|TESTSUB|" .. nonce
  elseif mode == "korean" then
    payload = "WCN2|" .. tostring(time()) .. "|0|0|스톰윈드|상업 지구|" .. nonce
  elseif mode == "queued" then
    payload = queuedPayload
    if not payload then say("진단: 대기 데이터 없음. /wcn queue 확인"); return end
  else
    return
  end
  say("진단[" .. mode .. "] 길이=" .. tostring(#payload) .. " 데이터=" .. payload)
  local ok, result = pcall(C_Club.SendMessage, clubId, streamId, payload)
  say("진단[" .. mode .. "] pcall=" .. tostring(ok) .. " / 반환=" .. tostring(result) .. " (게시 여부는 채팅방 확인)")
  if ok then
    lastPayload = payload
    pendingConfirm = {payload=payload, at=time(), lastNotice=0}
  end
end

-- v0.7: standard in-game addon channel; no external network or community chat posting.
-- Messages are advisory observations, never executable Lua.
local function registerNetwork()
  if not C_ChatInfo or type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function" then return false end
  local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_PREFIX)
  return ok and result ~= false
end
local function sendNetwork()
  if not canObserveOutdoors() then return end
  if not netEnabled or not ready or not db or not db.log then return end
  if not C_ChatInfo or type(C_ChatInfo.SendAddonMessage) ~= "function" then return end
  local r
  for i=#db.log,1,-1 do if db.log[i].source == "local" then r=db.log[i];break end end
  if not r or time()-r.at > freshSeconds() then return end
  if r.zone==Wacheonui_WeatherZoneKey(GetZoneText and GetZoneText() or "",GetSubZoneText and GetSubZoneText() or "") and r.layer~=currentLayer() then return end
  local sig=table.concat({r.zone,tostring(r.kind),tostring(r.intensity),r.layer or "?"}, "|")
  if sig == netLastSig and time()-netLastSent < 120 then return end
  if time()-netLastSent < 15 then return end
  local payload=table.concat({"W9",r.at,r.kind,r.intensity,cleanField(r.zone),cleanField(r.subzone),(type(r.layer)=="string" and r.layer:match("^Z%d+$")) and r.layer or "?"},"|")
  local sent=false
  local channels={}
  if IsInGuild and IsInGuild() then channels[#channels+1]="GUILD" end
  if IsInRaid and IsInRaid() then channels[#channels+1]="RAID"
  elseif IsInGroup and IsInGroup() then channels[#channels+1]="PARTY" end
  for _,channel in ipairs(channels) do
    local ok,result=pcall(C_ChatInfo.SendAddonMessage,ADDON_PREFIX,payload,channel)
    if ok and result ~= false then sent=true end
  end
  if sent then netLastSent=time();netLastSig=sig;netSent=netSent+1 end
end
-- Party/raid initial synchronization: request once on joining, then share
-- fresh region snapshots only. No observer names or counts in payloads.
local function groupChannel()
  if IsInRaid and IsInRaid() then return "RAID" end
  if IsInGroup and IsInGroup() then return "PARTY" end
  return nil
end
local function networkPost(payload, channel)
  if not netEnabled or not ready or not C_ChatInfo or
     type(C_ChatInfo.SendAddonMessage) ~= "function" then return false end
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, channel)
  return ok and result ~= false
end
local function requestSync(force)
  local channel = groupChannel()
  if not channel or not netEnabled then return false end
  if not force and time()-syncLastRequest < SYNC_COOLDOWN then return false end
  syncNonce = syncNonce + 1
  local nonce = tostring(time()) .. "-" .. tostring(syncNonce)
  if networkPost("W7Q|" .. nonce, channel) then
    syncOutstanding[nonce]=time()+20
    syncLastRequest=time();syncRequests=syncRequests+1
    if debugMode then say("초기 관측 정보 요청: "..channel) end
    return true
  end
  return false
end
local function buildSyncSnapshot()
  local newest={}
  if not db or not db.log then return {} end
  local now=time()
  for _,r in ipairs(db.log) do
    if type(r)=="table" and type(r.zone)=="string" and
       type(r.at)=="number" and type(r.kind)=="number" and
       type(r.intensity)=="number" and r.at>=now-freshSeconds() and r.at<=now+30 then
      local key=r.zone.."@"..((type(r.layer)=="string" and r.layer:match("^Z%d+$")) and r.layer or "?")
      if not conflictFor(r.zone) and (not newest[key] or newest[key].at<r.at) then newest[key]=r end
    end
  end
  local rows={}
  for _,r in pairs(newest) do rows[#rows+1]=r end
  table.sort(rows,function(a,b) return a.at>b.at end)
  return rows
end
local function sendSyncBatch()
  if not syncPending then return end
  local task=syncPending
  if GetTime()<task.due then return end
  if not netEnabled or groupChannel()~=task.channel then syncPending=nil;return end
  local r=task.rows[task.index]
  if not r or task.index>SYNC_MAX_PER_RESPONSE then syncPending=nil;return end
  local payload=table.concat({"W9S",task.nonce,r.at,r.kind,r.intensity,
    cleanField(r.zone),cleanField(r.subzone),(type(r.layer)=="string" and r.layer:match("^Z%d+$")) and r.layer or "?"},"|")
  if #payload<=240 and networkPost(payload,task.channel) then syncSent=syncSent+1 end
  task.index=task.index+1
  task.due=GetTime()+0.35 -- throttle snapshot replies
end
local function receiveSyncRequest(payload,channel,sender)
  if not groupChannel() or channel~=groupChannel() then return end
  local nonce=payload:match("^W7Q|([%d%-]+)$")
  if not nonce or #nonce>40 then return end
  local rows=buildSyncSnapshot()
  if #rows==0 then return end
  -- A short randomized delay avoids every client responding at once.
  syncPending={channel=channel,nonce=nonce,rows=rows,index=1,
    due=GetTime()+0.5+math.random()*1.5}
end
local diagPending = nil
local diagReplies = {}
local function diagLine(message)
  diagReplies[#diagReplies+1] = date("%H:%M:%S") .. " " .. message
  if #diagReplies > 30 then table.remove(diagReplies, 1) end
end
local function sendPing()
  if not netEnabled then diagLine("통신 비활성화"); return end
  local nonce = tostring(time()) .. tostring(math.random(100,999))
  diagPending = {nonce=nonce, at=GetTime(), replies=0}
  local n=0
  for _,channel in ipairs({"GUILD", "PARTY", "RAID"}) do
    local available = (channel=="GUILD" and IsInGuild and IsInGuild()) or
      (channel=="PARTY" and IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid())) or
      (channel=="RAID" and IsInRaid and IsInRaid())
    if available and networkPost("W7P|"..nonce,channel) then n=n+1 end
  end
  diagLine("PING 송신 경로="..n.." (응답 대기)")
end
Wacheonui_GetDiagnostics = function()
  local lines={"애드온 통신="..tostring(netEnabled).." / 송신="..netSent.." / 관측 수신="..netReceived,
    "길드="..tostring(IsInGuild and IsInGuild()).." / 파티="..tostring(IsInGroup and IsInGroup())}
  for _,line in ipairs(diagReplies) do lines[#lines+1]=line end
  return table.concat(lines,"\n")
end
Wacheonui_Ping = sendPing
local function receiveNetwork(prefix, payload, channel, sender)
  if not netEnabled or prefix ~= ADDON_PREFIX or type(payload)~="string" or #payload>240 then return end
  if type(sender)~="string" or sender=="" or sameCharacter(sender,myName) then return end
  local pingNonce=payload:match("^W7P|([%d]+)$")
  if pingNonce then
    if #pingNonce <= 30 then networkPost("W7R|"..pingNonce,channel) end
    return
  end
  local pongNonce=payload:match("^W7R|([%d]+)$")
  if pongNonce then
    if diagPending and diagPending.nonce==pongNonce then
      diagPending.replies=diagPending.replies+1
      diagLine("PONG "..sender.." / "..channel.." / "..math.floor((GetTime()-diagPending.at)*1000).."ms")
    end
    return
  end
  if payload:sub(1,4)=="W7Q|" then
    receiveSyncRequest(payload,channel,sender)
    return
  end
  local isSync=payload:sub(1,3)=="W7S" or payload:sub(1,3)=="W8S" or payload:sub(1,3)=="W9S"
  local stamp,kind,intensity,zone,subzone,layer
  if isSync then
    local nonce
    nonce,stamp,kind,intensity,zone,subzone,layer=payload:match("^W9S|([%d%-]+)|(%d+)|(%d+)|([%d%.]+)|([^|]+)|([^|]*)|([%d%?Z]+)$")
    if not nonce then nonce,stamp,kind,intensity,zone,subzone,layer=payload:match("^W8S|([%d%-]+)|(%d+)|(%d+)|([%d%.]+)|([^|]+)|([^|]*)|([%d%?Z]+)$"); layer=nil end
    if not nonce then nonce,stamp,kind,intensity,zone,subzone=payload:match("^W7S|([%d%-]+)|(%d+)|(%d+)|([%d%.]+)|([^|]+)|([^|]*)$") end
    if not nonce then return end
    if not syncOutstanding[nonce] or syncOutstanding[nonce]<time() then return end
  else
    stamp,kind,intensity,zone,subzone,layer=payload:match("^W9|(%d+)|(%d+)|([%d%.]+)|([^|]+)|([^|]*)|([%d%?Z]+)$")
    if not stamp then stamp,kind,intensity,zone,subzone,layer=payload:match("^W8|(%d+)|(%d+)|([%d%.]+)|([^|]+)|([^|]*)|([%d%?Z]+)$"); layer=nil end
    if not stamp then stamp,kind,intensity,zone,subzone=payload:match("^W7|(%d+)|(%d+)|([%d%.]+)|([^|]+)|([^|]*)$") end
  end
  if layer=="?" then layer=nil end
  -- Older clients sent the third GUID field as a layer; it is incompatible.
  if layer and not layer:match("^Z%d+$") then layer=nil end
  if isSync and channel~=groupChannel() then return end
  stamp,kind,intensity=tonumber(stamp),tonumber(kind),tonumber(intensity)
  if not stamp or not kind or not intensity or not zone or #zone>80 or #subzone>80 then return end
  if stamp>time()+30 or stamp<time()-freshSeconds() or kind<0 or kind>20 or intensity<0 or intensity>10 then return end
  local key=table.concat({sender,stamp,zone,kind,intensity,layer or "?"},"|")
  if db.seen[key] then return end
  db.seen[key]=true
  netReceived=netReceived+1
  addRecord(sender,zone,subzone,kind,intensity,stamp,"addon",layer)
  if isSync then syncReceived=syncReceived+1 end
end

local function command(msg)
  local cmd, arg = trim(msg):match("^(%S+)%s*(.-)$")
  cmd = (cmd or "help"):lower()
  if cmd == "layer" then
    sampleLayer("target");sampleLayer("mouseover")
    say("현재 지역 GUID zoneUID 지문(미검증): "..(currentLayer() or "미확인").." (NPC 대상 선택 후 /wcn layer)")
  elseif cmd == "build" then
    local version, build, buildDate, interface = GetBuildInfo()
    local iface = tonumber(interface) or 0
    say("와천의 v0.8.9 / 클라이언트 "..tostring(version).."."..tostring(build).." / 인터페이스 "..tostring(iface).." / "..tostring(buildDate))
    say("포에버 인터페이스: "..(iface >= 16000 and iface < 17000 and "범위 일치" or "확인 필요"))
    say("날씨 API: GetCurrentWeather="..tostring(C_Weather and type(C_Weather.GetCurrentWeather) == "function").." / GetWeather="..tostring(C_Weather and type(C_Weather.GetWeather) == "function"))
    say("애드온 통신 API: "..tostring(C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function").." / 지도 API: "..tostring(C_Map and type(C_Map.GetMapInfo) == "function"))
    local w, err = weather()
    say("현재 날씨 응답: "..(w and ("종류="..tostring(w.kind)..", 강도="..tostring(w.intensity)) or tostring(err)))
  elseif cmd == "dbcheck" then
    local d = WacheonuiStatic70707
    if not d then say("DB2 참조 데이터 없음") return end
    local n, a, w = 0, 0, 0
    for _ in pairs(d.maps) do n=n+1 end
    for _ in pairs(d.areaToMaps) do a=a+1 end
    for _ in pairs(d.weatherTypes) do w=w+1 end
    say("DB2 KR "..d.build.." / 지도="..n.." / 지도 연결 지역="..a.." / 날씨 설정="..w)
    say("DB2는 정적 참조 정보입니다. 실시간 날씨 및 지도 핀 위치는 기존 API 사용")
  elseif cmd == "netstatus" then
    say("애드온 통신: "..(netEnabled and "ON" or "OFF").." / 송신 API 호출="..netSent.." / 수신="..netReceived.." (길드/파티/공격대)")
  elseif cmd == "syncstatus" then
    say("초기 동기화: 요청="..syncRequests.." / 응답 송신="..syncSent.." / 응답 수신="..syncReceived)
  elseif cmd == "sync" then
    say(requestSync(true) and "초기 동기화 요청 전송" or "요청 실패: 파티/공격대 및 통신 상태 확인")
  elseif cmd == "neton" then
    db.netEnabled=true;netEnabled=registerNetwork();say("애드온 통신: "..tostring(netEnabled))
  elseif cmd == "netoff" then
    db.netEnabled=false;netEnabled=false;say("애드온 통신 OFF")
  elseif cmd == "network" then
    local found = findCommunity()
    say("관측망: " .. (found and ("연결 / Club="..clubId.." Stream="..streamId) or "미연결 (커뮤니티 가입 및 채팅방 접근 확인)"))
    say("자동 공유: " .. (db.shareEnabled and "ON" or "OFF") .. " / /wcn share on|off")
  elseif cmd == "share" then
    if arg == "on" then db.shareEnabled = true; findCommunity(); lastMessageId = nil; say("공동 관측망 공유 ON")
    elseif arg == "off" then db.shareEnabled = false; say("공동 관측망 공유 OFF")
    else say("사용법: /wcn share on|off") end
  elseif cmd == "add" then
    local name = normalizeName(arg)
    if not name then say("사용법: /wcn add 캐릭터명"); return end
    say("v0.6에서는 귓속말 관측자 등록을 사용하지 않습니다. /wcn network")
  elseif cmd == "remove" then
    local name = normalizeName(arg)
    if name then db.peers[name] = nil; say("이전 관측자 등록 삭제: " .. name) end
  elseif cmd == "peers" then
    local n=0
    for name, enabled in pairs(db.peers) do if enabled then say("관측자: " .. name); n=n+1 end end
    if n==0 then say("등록된 관측자가 없습니다.") end
  elseif cmd == "send" then
    sendQueuedFromCommand()
  elseif cmd == "queue" then
    say("대기 관측: " .. (queuedZone or "없음") .. " / 자동 송신: OFF (클라이언트 테스트 결과)")
  elseif cmd == "testascii" then
    diagnosticPayload("ascii")
  elseif cmd == "testkorean" then
    diagnosticPayload("korean")
  elseif cmd == "testqueued" then
    diagnosticPayload("queued")
  elseif cmd == "testdirect" then
    diagnosticSend("direct")
  elseif cmd == "testdelay" then
    diagnosticSend("deferred")
  elseif cmd == "payload" then
    say("마지막 송신: " .. tostring(lastPayload or "없음"))
    say("게시 확인: " .. (pendingConfirm and "대기" or (lastPosted and ("최근 확인 " .. date("%H:%M:%S",lastPosted)) or "확인 이력 없음")))
  elseif cmd == "status" then
    local w, err = weather()
    local z = zoneInfo() or "지역 미확인"
    say("현재 지역: " .. z .. (w and (" / type="..w.kind.." intensity="..w.intensity) or (" / "..err)))
    say("저장된 관측: " .. #db.log .. "건 / 커뮤니티 " .. (clubId and "연결" or "미연결") .. " / 공유 " .. (db.shareEnabled and "ON" or "OFF"))
    say("자동 송신: 비활성화 / 수동 전송: /wcn send / 대기: " .. (queuedZone or "없음"))
  elseif cmd == "log" then
    local start = math.max(1, #db.log - 9)
    for i=start,#db.log do
      local r=db.log[i]
      say(string.format("%s | %s | %s | %s/%s", date("%m-%d %H:%M", r.at), "익명", r.zone, r.kind, r.intensity))
    end
    if #db.log==0 then say("관측 기록 없음") end
  elseif cmd == "history" then
    local filter = trim(arg)
    local matches = {}
    for _, r in ipairs(db.log) do
      if filter == "" or r.zone:find(filter, 1, true) then matches[#matches+1] = r end
    end
    say("관측 이력: " .. #matches .. "건" .. (filter ~= "" and (" / 지역: " .. filter) or "") .. " (최근 최대 15건)")
    for i=math.max(1,#matches-14),#matches do
      local r=matches[i]
      say(string.format("%s | %s | %s | type=%s intensity=%s [%s]",date("%m-%d %H:%M:%S",r.at),"익명",r.zone,tostring(r.kind),tostring(r.intensity),r.source or "?"))
    end
  elseif cmd == "captureunknown" then
    if not canObserveOutdoors() then say("인스턴스에서는 기상 진단을 저장하지 않습니다."); return end
    local w, err = weather()
    if not w then say("날씨 API 응답 없음: "..tostring(err)); return end
    local zone, subzone = zoneInfo()
    if not zone then say("지역 확인 실패: 저장하지 않았습니다."); return end
    db.weatherSnapshots = db.weatherSnapshots or {}
    local version, build = GetBuildInfo()
    local record={at=time(),zone=zone,subzone=subzone,kind=w.kind,intensity=w.intensity,
      build=tostring(build or version or "?"),unrecognized=not KNOWN_TYPES[w.kind]}
    db.weatherSnapshots[#db.weatherSnapshots+1]=record
    while #db.weatherSnapshots>100 do table.remove(db.weatherSnapshots,1) end
    if record.unrecognized then
      local key=tostring(w.kind)
      db.discoveries[key]=db.discoveries[key] or {first=record.at,zone=zone,observer=myName}
      db.discoveries[key].last=record.at
    end
    say("기상 원본값 저장: type="..tostring(w.kind).." intensity="..tostring(w.intensity).." / "..zone..
      (record.unrecognized and " [새로운 유형 후보]" or " [기존 API 유형: 시각 효과와 다를 수 있음]"))
    say("이 기록은 진단용이며 현재 날씨로 강제 반영하거나 자동 공유하지 않습니다.")
  elseif cmd == "captures" then
    local snapshots=db.weatherSnapshots or {}
    say("수동 기상 API 기록 "..#snapshots.."건 (최근 최대 10건)")
    for i=math.max(1,#snapshots-9),#snapshots do
      local r=snapshots[i]
      say(string.format("%s | %s | type=%s intensity=%s | build=%s%s",
        date("%m-%d %H:%M",r.at),r.zone,tostring(r.kind),tostring(r.intensity),tostring(r.build or "?"),
        r.unrecognized and " [미확인]" or ""))
    end
  elseif cmd == "discoveries" then
    local n=0
    for kind, r in pairs(db.discoveries) do
      n=n+1
      say(string.format("미확인 type=%s | 최초 %s (%s) | 최근 %s",kind,date("%m-%d %H:%M",r.first),r.zone,date("%m-%d %H:%M",r.last or r.first)))
    end
    if n==0 then say("미확인 기상 유형 기록 없음 (0~2 외 값은 별도 기록)") end
  elseif cmd == "report" then
    if not canObserveOutdoors() then say("인스턴스에서는 날씨 제보를 기록하지 않습니다."); return end
    local key, note = trim(arg):match("^(%S+)%s*(.-)$")
    key = key and key:lower()
    if not key or not REPORT_TYPES[key] then
      say("사용법: /wcn report thunder|lightning|wind|fog|other [메모]")
      return
    end
    local zone, subzone = zoneInfo()
    if not zone then say("지역을 확인할 수 없습니다."); return end
    note = cleanField(note):sub(1,80)
    local r={at=time(),zone=zone,subzone=subzone,kind=key,label=REPORT_TYPES[key],note=note,observer=myName,source="manual"}
    db.reports[#db.reports+1]=r
    while #db.reports>MAX_REPORTS do table.remove(db.reports,1) end
    say("현장 제보 기록: "..r.label.." / "..zone.." (자동 측정 아님, 다른 캐릭터로 전송되지 않음)")
  elseif cmd == "reports" then
    say("수동 제보: "..#db.reports.."건 (최근 최대 10건)")
    for i=math.max(1,#db.reports-9),#db.reports do
      local r=db.reports[i]
      say(string.format("%s | %s | %s%s",date("%m-%d %H:%M",r.at),r.zone,r.label,r.note~="" and (" / "..r.note) or ""))
    end
  elseif cmd == "toggle" then
    db.mapEnabled = not db.mapEnabled
    refreshMap()
    say("지도 표시: " .. (db.mapEnabled and "ON" or "OFF"))
  elseif cmd == "map" then
    if WorldMapFrame then WorldMapFrame:Show(); refreshMap() else say("월드맵 프레임 없음") end
  elseif cmd == "debug" then
    debugMode = not debugMode
    say("디버그: " .. (debugMode and "ON" or "OFF"))
  else
    say("명령어: /wcn build | sync | syncstatus | netstatus | network | share on|off | status | send | queue | testdirect | testascii | testkorean | testqueued | testdelay | payload | log | history [지역] | captureunknown | captures | discoveries | report 종류 [메모] | reports | map | toggle | debug")
  end
end

SLASH_WACHEONUI1 = "/wcn"
SLASH_WACHEONUI2 = "/와천의"
SlashCmdList["WACHEONUI"] = command
Wacheonui_RunCommand = command
SLASH_WACHEONUISET1 = "/wcnui"
SlashCmdList["WACHEONUISET"] = function() if Wacheonui_ToggleSettings then Wacheonui_ToggleSettings() end end
SLASH_WACHEONUIPING1 = "/wcnping"
SlashCmdList["WACHEONUIPING"] = sendPing

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ZONE_CHANGED")
f:RegisterEvent("ZONE_CHANGED_INDOORS")
f:RegisterEvent("WEATHER_CHANGED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
-- Nameplate GUIDs may be secret in dungeons; avoid sampling them.
-- f:RegisterEvent("NAME_PLATE_UNIT_ADDED")

f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    WacheonuiDB = WacheonuiDB or {}
    db = WacheonuiDB
    db.peers = db.peers or {}
    db.log = db.log or {}
    db.latest = db.latest or {}
    db.lastKnown = db.lastKnown or {}
    -- One-time recovery of latest observations from existing history.
    for _,r in ipairs(db.log) do
      if type(r)=="table" and type(r.zone)=="string" and type(r.at)=="number" then
        local key=Wacheonui_WeatherZoneKey(r.zone,r.subzone).."|"..tostring(r.layer or "?")
        local old=db.lastKnown[key]
        if not old or type(old.at)~="number" or r.at>old.at then db.lastKnown[key]=r end
      end
    end
    db.seen = db.seen or {}
    db.discoveries = db.discoveries or {}
    db.weatherConflicts = db.weatherConflicts or {}
    db.reports = db.reports or {}
    db.weatherSnapshots = db.weatherSnapshots or {}
    db.mapEnabled = db.mapEnabled ~= false
    if db.freshSeconds == nil then db.freshSeconds = 1800 end
    if db.shareEnabled == nil then db.shareEnabled = false end -- legacy community setting
    if db.netEnabled == nil then db.netEnabled = true end
    netEnabled = db.netEnabled and registerNetwork()
    myName = UnitName("player") or "Unknown"
    myRealm = GetRealmName and GetRealmName() or ""
    findCommunity()
    ready = true
    publish("접속", false)
    -- Initial request after the client has finished entering the world.
    syncPending=nil
    syncOutstanding={}
  elseif event == "PLAYER_TARGET_CHANGED" and ready then
    sampleLayer("target")
  elseif event == "UPDATE_MOUSEOVER_UNIT" and ready then
    sampleLayer("mouseover")
  elseif event == "NAME_PLATE_UNIT_ADDED" and ready then
    sampleLayer(...)
  elseif event == "GROUP_ROSTER_UPDATE" and ready then
    local channel=groupChannel()
    if channel and not syncRosterKey then requestSync(false) end
    syncRosterKey=channel
  elseif event == "PLAYER_ENTERING_WORLD" and ready then
    layerRaw=nil;layerSeenAt=0;layerZone=nil
    resetOutdoorObservation()
    if canObserveOutdoors() then publish(event, false) end
    requestSync(false)
  elseif event == "CHAT_MSG_ADDON" and ready then
    receiveNetwork(...)
  elseif ready then
    if event=="ZONE_CHANGED_NEW_AREA" then layerRaw=nil;layerSeenAt=0;layerZone=nil end
    if canObserveOutdoors() then publish(event, false) else resetOutdoorObservation() end
  end
end)

-- Community messages are not delivered by CHAT_MSG_* on this tested client.
-- Polling is read-only. Do not call SendMessage from OnUpdate.
local elapsed = 0
f:SetScript("OnUpdate", function(_, dt)
  if not ready then return end
  if diagnosticDeferred then
    local payload = diagnosticDeferred
    diagnosticDeferred = nil
    local ok, result = pcall(C_Club.SendMessage, clubId, streamId, payload)
    say("진단 지연 호출: " .. payload .. " / pcall=" .. tostring(ok) .. " / 반환=" .. tostring(result))
    say("실제 게시 여부는 커뮤니티 채팅방에서 확인해 주세요.")
  end
  sendSyncBatch()
  -- Expire request tokens so unsolicited replayed snapshots are ignored.
  if math.random(1,100)==1 then
    for nonce,expires in pairs(syncOutstanding) do
      if expires<time() then syncOutstanding[nonce]=nil end
    end
  end
  netElapsed = netElapsed + dt
  if netElapsed >= 10 then
    netElapsed = 0; publish("정기 관측", false); sendNetwork()
    if groupChannel() and not syncRosterKey then requestSync(false);syncRosterKey=groupChannel() end
  end
  elapsed = elapsed + dt
  if elapsed >= 1 then
    elapsed = 0
    if pendingReason and time() - lastSendAt >= SEND_COOLDOWN then lastSignature = nil; publish(pendingReason, false) end
  end
  pollElapsed = pollElapsed + dt
  discoverElapsed = discoverElapsed + dt
  if discoverElapsed >= DISCOVER_SECONDS then
    discoverElapsed = 0
    if not clubId then findCommunity() end
  end
  if pollElapsed >= POLL_SECONDS then
    pollElapsed = 0
    pollCommunity()
  end
end)
