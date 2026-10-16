-- lua spec/run.lua          unit tests against recorded response shapes
-- lua spec/run.lua live     plus two free live checks (needs EMAKI_API_KEY)
package.path = "src/?.lua;" .. package.path
local emaki = require("emaki")
local function check(ok, what) if not ok then error("FAIL " .. what) end print("ok  " .. what) end

local real_transport = emaki.transport
local calls, script = {}, {}
emaki.sleep = function() end
emaki.transport = function(url, body)
  calls[#calls + 1] = { url = url, body = body }
  local r = table.remove(script, 1)
  return r[1], r[2]
end

-- submit -> generating -> completed
script = {
  { 200, { success = true, data = { id = "v1", status = "generating" } } },
  { 200, { success = true, data = { id = "v1", status = "generating" } } },
  { 200, { success = true, data = { id = "v1", status = "completed", videoUrl = "https://cdn.emaki.ai/v1.mp4" } } },
}
local url = emaki.generate_video("a fox", { duration = 6 }, { api_key = "sk-x" })
check(url == "https://cdn.emaki.ai/v1.mp4", "video returns videoUrl")
check(calls[1].url:match("/api/video/ai$") and calls[1].body.model == "seedance_2_5", "default video model")
check(calls[1].body.parameters.duration == 6, "parameters passed through")
check(calls[2].url:match("/api/video/status$") and calls[2].body.videoId == "v1", "polls by videoId")

calls = {}
script = {
  { 200, { success = true, data = { id = "i1", status = "generating" } } },
  { 200, { success = true, data = { id = "i1", status = "completed", videoUrl = "https://cdn.emaki.ai/i1.png" } } },
}
check(emaki.generate_image("a mug", nil, { api_key = "sk-x" }) == "https://cdn.emaki.ai/i1.png", "image url")
check(calls[1].body.model == "nano_banana_2_lite" and calls[1].body.parameters == nil, "default image model")

script = {
  { 200, { success = true, data = { id = "f1", status = "generating" } } },
  { 200, { success = true, data = { id = "f1", status = "failed", failureCode = "provider_error" } } },
}
local _, err = emaki.generate_video("x", nil, { api_key = "sk-x" })
check(err.reason == "failed" and err.message:find("provider_error", 1, true), "failed carries failureCode")

local cases = {
  { 401, { error = "Invalid API key. Create one at https://emaki.ai/settings/apikeys" }, "auth" },
  { 402, { error = "Insufficient credits" }, "quota" },
  { 403, { error = "This model requires a purchase" }, "plan" },
  { 409, { error = "Video generation is already in progress" }, "busy" },
  { 429, { error = "cooling down", code = "content_cooldown" }, "rejected" },
  { 400, { error = "blocked", code = "content_blocked" }, "rejected" },
  { 400, { error = "Missing required parameters: prompt and model" }, "validation" },
  { 500, { error = "Internal error" }, "other" },
}
for _, c in ipairs(cases) do
  script = { { c[1], c[2] } }
  local id, e = emaki.submit("x", nil, nil, { api_key = "sk-x" })
  check(id == nil and e.reason == c[3] and e.status == c[1], c[1] .. " -> " .. c[3])
end

script = { { 200, { code = 0, message = "ok", data = { remainingCredits = 42, hasPurchasedCredits = false } } } }
check(emaki.credits({ api_key = "sk-x" }) == 42, "credits")
script = { { 200, { code = -1, message = "Invalid API key. Create one at https://emaki.ai/settings/apikeys" } } }
local n, ce = emaki.credits({ api_key = "sk-x" })
check(n == nil and ce.reason == "auth", "credits code -1 -> auth")
if not os.getenv("EMAKI_API_KEY") then
  local _, ke = emaki.submit("x", nil, nil, { api_key = "" })
  check(ke.reason == "auth", "missing key -> auth")
end

if arg[1] == "live" then
  emaki.transport = real_transport
  local left, lerr = emaki.credits()
  check(type(left) == "number", "live credits() = " .. tostring(left) .. (lerr and lerr.message or ""))
  local id, werr = emaki.submit("live check", "nano_banana_2_lite", nil, { api_key = "sk-wrong-key" })
  check(id == nil and werr.reason == "auth" and werr.status == 401, "live wrong key -> auth (" .. tostring(werr and werr.status) .. ")")
end
print("all tests passed")
