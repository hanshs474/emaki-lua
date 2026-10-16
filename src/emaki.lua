--- Official Lua SDK for emaki (https://emaki.ai): generate Seedance 2.5 and
-- Seedance 2.0 clips, and images, with the API key of your emaki account.
--
--   local emaki = require("emaki")
--   local url, err = emaki.generate_video("a paper lantern drifting down a night river")
--   if url then print(url) else print(err.reason, err.message) end
--
-- Pass opts.api_key or set EMAKI_API_KEY; create a key at
-- https://emaki.ai/settings/apikeys.
--
-- Failures come back as nil plus { reason = ..., message = ..., status = ... }
-- where reason is "auth", "quota", "plan", "busy", "rejected", "validation",
-- "failed", "timeout" or "other".

local json = require("dkjson")

local M = { _VERSION = "0.1.0", base_url = "https://emaki.ai" }

M.KEYS_URL = "https://emaki.ai/settings/apikeys"
M.VIDEO_MODEL = "seedance_2_5"
M.IMAGE_MODEL = "nano_banana_2_lite"

--- POST a JSON body; return HTTP status and the decoded body. Replaceable in tests.
function M.transport(url, body, key)
  local https = require("ssl.https")
  local ltn12 = require("ltn12")
  local out = {}
  local payload = json.encode(body)
  local _, code = https.request({
    url = url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload),
      ["Authorization"] = "Bearer " .. key,
      ["User-Agent"] = "emaki-lua/" .. M._VERSION,
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(out),
  })
  if type(code) ~= "number" then return nil, nil, tostring(code) end
  return code, json.decode(table.concat(out))
end

--- Sleep between polls. Replaceable in tests.
function M.sleep(seconds)
  local ok, socket = pcall(require, "socket")
  if ok then socket.sleep(seconds) else os.execute("sleep " .. tonumber(seconds)) end
end

--- Map an HTTP status and error body to the reason that says what to do next.
function M.classify(status, body)
  local code = type(body) == "table" and body.code or nil
  if status == 401 then return "auth" end
  if status == 402 then return "quota" end
  if status == 403 then return "plan" end
  if status == 409 then return "busy" end
  if code == "content_cooldown" or code == "content_blocked" then return "rejected" end
  if status == 400 then return "validation" end
  return "other"
end

local function fail(reason, message, status)
  return nil, { reason = reason, message = "emaki: " .. message, status = status }
end

local function key_of(opts)
  if opts.api_key and opts.api_key ~= "" then return opts.api_key end
  local env = os.getenv("EMAKI_API_KEY")
  if env and env ~= "" then return env end
  return nil
end

local function call(path, body, opts)
  local key = key_of(opts)
  if not key then return fail("auth", "an API key is required; create one at " .. M.KEYS_URL) end
  local status, data, terr = M.transport((opts.base_url or M.base_url) .. path, body, key)
  if not status then return fail("other", terr or "no answer") end
  if status >= 200 and status < 300 and type(data) == "table" then return data end
  local msg = type(data) == "table" and (data.error or data.message) or ("HTTP " .. status)
  return fail(M.classify(status, data), tostring(msg), status)
end

--- Submit a run and return its id without waiting.
-- params is passed through as the request's `parameters` (duration, resolution, aspect_ratio, image, ...).
function M.submit(prompt, model, params, opts)
  opts = opts or {}
  if type(prompt) ~= "string" or not prompt:find("%S") then return fail("validation", "prompt is required") end
  local body = { prompt = prompt, model = model or M.VIDEO_MODEL }
  if params and next(params) then body.parameters = params end
  local data, err = call("/api/video/ai", body, opts)
  if not data then return nil, err end
  if type(data.data) ~= "table" or not data.data.id then return fail("other", "the service returned no id") end
  return data.data.id
end

--- Return the run's record: { id, status = "generating"|"completed"|"failed", videoUrl, failureCode }.
function M.status(id, opts)
  local data, err = call("/api/video/status", { videoId = id }, opts or {})
  if not data then return nil, err end
  return data.data
end

--- Remaining credits on the account (free to call).
function M.credits(opts)
  opts = opts or {}
  local data, err = call("/api/user/get-user-credits", {}, opts)
  if not data then return nil, err end
  -- This endpoint answers refusals with HTTP 200 and code -1.
  if data.code ~= 0 then
    local msg = tostring(data.message or "request refused")
    return fail(msg:lower():find("api key", 1, true) and "auth" or "other", msg)
  end
  return data.data.remainingCredits
end

--- Poll a submitted run every opts.poll_every seconds (5) until done or opts.timeout (900), return the URL.
function M.wait(id, opts)
  opts = opts or {}
  local every, waited, limit = opts.poll_every or 5, 0, opts.timeout or 900
  while waited < limit do
    M.sleep(every)
    waited = waited + math.max(every, 0.001)
    local rec, err = M.status(id, opts)
    if rec then
      if rec.status == "completed" and rec.videoUrl then return rec.videoUrl end
      if rec.status == "failed" then
        return fail("failed", "the run failed (" .. tostring(rec.failureCode or "unknown") .. ")")
      end
    elseif err.reason == "auth" then
      return nil, err
    end -- a dropped poll is not a failed run
  end
  return fail("timeout", "deadline passed; the run may still finish in your emaki library")
end

--- Generate one clip and return its URL. Default model seedance_2_5.
function M.generate_video(prompt, params, opts)
  opts = opts or {}
  local id, err = M.submit(prompt, opts.model or M.VIDEO_MODEL, params, opts)
  if not id then return nil, err end
  return M.wait(id, opts)
end

--- Generate one image and return its URL. Default model nano_banana_2_lite.
function M.generate_image(prompt, params, opts)
  opts = opts or {}
  local id, err = M.submit(prompt, opts.model or M.IMAGE_MODEL, params, opts)
  if not id then return nil, err end
  return M.wait(id, opts)
end

return M
