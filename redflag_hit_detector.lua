local RedFlagHitHandler = {}

function RedFlagHitHandler:onEvent(event)
    -- Check if the event is a HIT (event id 2)
    if event.id == 2 and event.target then
        local targetUnit = event.target
        local targetName = targetUnit:getName()

        -- Check if the unit hit belongs to a human player
        if targetUnit:getPlayerName() ~= nil then
            local playerName = targetUnit:getPlayerName()
            local unitTypeName = targetUnit:getTypeName()

            -- Display the Red Flag Training message
            local messageText = string.format(
                "\n=== SHOWTIME (WHITE CELL) MSG ===\n" ..
                "Attention %s (%s)!\n" ..
                "You have been HIT by a simulated threat.\n" ..
                "KNOCK IT OFF! Break off engagement and reset behind the fallback line.", 
                playerName, targetName
            )

            -- Send message to all players for 15 seconds
            trigger.action.outText(messageText, 15)

            -- Optional: Play a default notification sound
            trigger.action.outSound("OldPhone.ogg") 
        end
    end
end

-- Force player immortality on mission start
local function SetPlayersImmortal()
    local coalitions = {coalition.side.BLUE, coalition.side.RED}
    for , side in ipairs(coalitions) do
        local groups = coalition.getGroups(side)
        for , group in ipairs(groups) do
            local units = group:getUnits()
            for _, unit in ipairs(units) do
                if unit:getPlayerName() ~= nil then
                    local groupController = group:getController()
                    -- Apply the built-in DCS command to lock invulnerability
                    local command = {
                        id = 'SetImmortal',
                        params = {
                            value = true
                        }
                    }
                    groupController:setCommand(command)
                end
            end
        end
    end
end 
