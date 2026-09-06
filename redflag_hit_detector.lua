-- Red Flag Hit Detection Script
local HitHandler = {}

function HitHandler:onEvent(event)
    -- Check if a hit event occurred and if the target was a human player
    if event.id == world.event.S_EVENT_HIT then
        local target = event.target

        if target and target:getPlayerName() then
            -- Customize your message and text duration (e.g., 15 seconds) below
            trigger.action.outText("REDFLAG CONTROL: Knock it Off! You have been HIT. Go to Marshal and wait for your flight.", 15)

            -- Optional: Play a default caution sound effect
            trigger.action.outSound("Effects/Aircrafts/Cockpits/MasterCaution.wav") 
        end
    end
end