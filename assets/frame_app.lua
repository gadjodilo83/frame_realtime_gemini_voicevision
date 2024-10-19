local data = require('data.min')
local battery = require('battery.min')
local code = require('code.min')
local plain_text = require('plain_text.min')

-- Phone to Frame flags
TEXT_MSG = 0x0b
START_AUDIO_MSG = 0x30
STOP_AUDIO_MSG = 0x31
TAP_SUBS_MSG = 0x10

-- register the message parser so it's automatically called when matching data comes in
data.parsers[TEXT_MSG] = plain_text.parse_plain_text
data.parsers[START_AUDIO_MSG] = code.parse_code
data.parsers[STOP_AUDIO_MSG] = code.parse_code
data.parsers[TAP_SUBS_MSG] = code.parse_code

-- Frame to Phone flags
AUDIO_DATA_NON_FINAL_MSG = 0x05
AUDIO_DATA_FINAL_MSG = 0x06
TAP_MSG = 0x09

function handle_tap()
	pcall(frame.bluetooth.send, string.char(TAP_MSG))
end

-- draw the current text on the display
function print_text()
    local i = 0
    for line in data.app_data[TEXT_MSG].string:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end
end

-- Main app loop
function app_loop()
	-- clear the display
	frame.display.text(" ", 1, 1)
	frame.display.show()
    local last_batt_update = 0
    local streaming = false
	local audio_data = ''
	local mtu = frame.bluetooth.max_length()
	-- data buffer needs to be even for reading from microphone
	if mtu % 2 == 1 then mtu = mtu - 1 end

    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into image or text, then clear raw)
                local items_ready = data.process_raw_items()

                if items_ready > 0 then

                    if (data.app_data[TEXT_MSG] ~= nil and data.app_data[TEXT_MSG].string ~= nil) then
                        print_text()
                        frame.display.show()
                    end

                    if (data.app_data[TAP_SUBS_MSG] ~= nil) then

                        if data.app_data[TAP_SUBS_MSG].value == 1 then
                            -- start subscription to tap events
                            frame.imu.tap_callback(handle_tap)
                        else
                            -- cancel subscription to tap events
                            frame.imu.tap_callback(nil)
                        end

                        data.app_data[TAP_SUBS_MSG] = nil
                    end

                    if (data.app_data[START_AUDIO_MSG] ~= nil) then
                        audio_data = ''
                        pcall(frame.microphone.start, {sample_rate=8000, bit_depth=16})
                        streaming = true
                        frame.display.text("Streaming Audio", 1, 1)
                        frame.display.show()

                        data.app_data[START_AUDIO_MSG] = nil
                    end

                    if (data.app_data[STOP_AUDIO_MSG] ~= nil) then
                        pcall(frame.microphone.stop)
                        -- clear the display
                        frame.display.text(" ", 1, 1)
                        frame.display.show()

                        data.app_data[STOP_AUDIO_MSG] = nil
                    end
                end
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04)
            break
        end

        -- send any pending audio data back
		-- Streams until STOP_AUDIO_MSG is sent from phone
		-- (prioritize the reading and sending about 20x compared to checking for other events e.g. STOP_AUDIO_MSG)
        if streaming then
            for i=1,20 do
				audio_data = frame.microphone.read(mtu)

				-- Calling frame.microphone.stop() will allow this to break the loop
				if audio_data == nil then
					-- send an end-of-stream message back to the phone
					pcall(frame.bluetooth.send, string.char(AUDIO_DATA_FINAL_MSG))
					frame.sleep(0.0025)
					streaming = false
                    break

				-- send the data that was read
				elseif audio_data ~= '' then
					pcall(frame.bluetooth.send, string.char(AUDIO_DATA_NON_FINAL_MSG) .. audio_data)
					frame.sleep(0.0025)
				end
			end
		end

        -- periodic battery level updates, 120s
        last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 120)

		if not streaming then frame.sleep(0.1) end
    end
end

-- run the main app loop
app_loop()