--[[
  Copyright 2022 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION

  MQTT Device Driver - supports receiving MQTT published messages for recognized device types:  switch, button, contact, motion, etc.

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"          -- just for time
local log = require "log"

local procmsg = require "procmessages"
local sub = require "subscriptions"
local cmd = require "cmdhandlers"
local mqtt = require "mqtt"


-- Global variables
thisDriver = {}               -- used in the MQTT client module: TODO- pass it in at initialization
SUBSCRIBED_TOPICS = {}        -- referenced by other modules
client = nil                  -- referenced by other modules
creator_device = {}           -- referenced by other modules

typemeta =  {
              ['Switch']       = { ['profile'] = 'mqttswitch.v2',        ['created'] = 0, ['switch'] = true  },
              ['Button']       = { ['profile'] = 'mqttbutton.v2',        ['created'] = 0, ['switch'] = false },
              ['Contact']      = { ['profile'] = 'mqttcontact.v2',       ['created'] = 0, ['switch'] = false },
              ['Motion']       = { ['profile'] = 'mqttmotion.v2',        ['created'] = 0, ['switch'] = false },
              ['Alarm']        = { ['profile'] = 'mqttalarm.v2',         ['created'] = 0, ['switch'] = false },
              ['Dimmer']       = { ['profile'] = 'mqttdimmer.v3',        ['created'] = 0, ['switch'] = true },
              ['Acceleration'] = { ['profile'] = 'mqttaccel.v1',         ['created'] = 0, ['switch'] = false },
              ['Lock']         = { ['profile'] = 'mqttlock.v2',          ['created'] = 0, ['switch'] = false },
              ['Presence']     = { ['profile'] = 'mqttpresence.v1',      ['created'] = 0, ['switch'] = false },
              ['Sound']        = { ['profile'] = 'mqttsound.v1',         ['created'] = 0, ['switch'] = false },
              ['Water']        = { ['profile'] = 'mqttwater.v1',         ['created'] = 0, ['switch'] = false },
              ['Temperature']  = { ['profile'] = 'mqtttemp.v1',          ['created'] = 0, ['switch'] = false },
            }

-- Module variables

local initialized = false
local clearcreatemsg_timer
local shutdown_requested = false
local client_reset_inprogress = false
local MASTERPROFILE = 'mqttcreator.v2c'


-- Custom Capabilities
cap_createdev = capabilities["partyvoice23922.createmqttdev3"]
cap_status = capabilities["partyvoice23922.status"]
cap_topiclist = capabilities["partyvoice23922.topiclist"]
cap_refresh = capabilities["partyvoice23922.refresh"]

cap_tempset = capabilities["partyvoice23922.vtempset"]



local function schedule_subscribe()

  if client then
    sub.subscribe_all()
  else
    log.warn('Broker not yet connected')
    thisDriver:call_with_delay(2, schedule_subscribe)
  end
end


local function create_MQTT_client(device)

  local connect_args = {}
  connect_args.uri = device.preferences.broker
  connect_args.clean = true
  
  if device.preferences.userid ~= '' and device.preferences.password ~= '' then
    if device.preferences.userid ~= 'xxxxx' and device.preferences.password ~= 'xxxxx' then
      connect_args.username = device.preferences.userid
      connect_args.password = device.preferences.password
    end
  end

  -- create mqtt client
  client = mqtt.client(connect_args)

  client:on{
    connect = function(connack)
      if connack.rc ~= 0 then
        log.error ("connection to broker failed:", connack:reason_string(), connack)
        device:emit_event(cap_status.status('Failed to Connect to Broker'))
        return
      end
      log.info("Connected to MQTT broker:", connack) -- successful connection
      device:emit_event(cap_status.status('Connected to Broker'))
      thisDriver:call_with_delay(3, schedule_subscribe)
    end,

    message = function(msg)
      assert(client:acknowledge(msg))

      --log.info("received:", msg, type(msg))
      -- example msg:  PUBLISH{payload="Hello world", topic="testmqtt/pimylifeup", dup=false, type=3, qos=0, retain=false}

      procmsg.process_message(msg.topic, msg.payload)


    end,

    error = function(err)
      log.error("MQTT client error:", err)
    end,
  }

  return client

end


function init_mqtt(device)

  if client_reset_inprogress == true then; return; end
  
  if device == nil then; device = creator_device; end       -- needed if invoked via driver:call_with_delay() method

  if device.preferences.broker == '192.168.1.xxx' or
     device.preferences.subTopic == 'xxxxx/xxxxx' then

      log.warn ('Device settings not initialized')
      return
  end

  device:emit_event(cap_status.status('Connecting...'))
  
  -- If already connected, then unsubscribe alland  shutdown
  if client then
    log.debug ('Unsubscribing all and disconnecting current client...')
    
    sub.unsubscribe_all()

    local rc, err = client:disconnect()
    if rc == false then
      log.error ('\tDisconnect failed with err:', err)
    elseif rc == true then
      log.debug ('\tDisconnected from broker')
    end
  end

  client = create_MQTT_client(device)

  if client and (device:get_field('client_thread') ~= true) then
  
  -- Run MQTT loop in separate thread

    cosock.spawn(function()
      device:set_field('client_thread', true)
      while true do
        local ok, err = mqtt.run_sync(client)
        client = nil
        if ok == false then
          log.warn ('MQTT run_sync returned: ', err)
          if shutdown_requested == true then
            device:emit_event(cap_status.status('Driver shutdown'))
            return
          end
          if string.lower(err):find('connection refused', 1, 'plaintext') or err == "closed" then
            device:emit_event(cap_status.status('Reconnecting...'))
            device:emit_event(cap_topiclist.topiclist(' ', { visibility = { displayed = false } }))
            client_reset_inprogress = true
            repeat
              -- pause, then try to create new mqtt client
              cosock.socket.sleep(15)
              log.info ('Attempting to reconnect to broker...')
              client = create_MQTT_client(device)
            until client
            client_reset_inprogress = false
          else
            break
          end
        else
          log.error ('Unexpected return from MQTT client:', ok, err)
        end
      end
      device:set_field('client_thread', false)
    end, 'MQTT synch mode')

    -- Schedule device subscriptions
    --thisDriver:call_with_delay(3, schedule_subscribe)
    
  elseif client == nil then
    log.error ('Create MQTT Client failed')
    thisDriver:call_with_delay(15, init_mqtt)
  end
end

------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)

  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  
  if device.device_network_id:find('Master', 1, 'plaintext') then
  
    creator_device = device
    device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
    device:emit_event(cap_status.status('Not Connected'))
    device:emit_event(cap_topiclist.topiclist(' ', { visibility = { displayed = false } }))
    
    initialized = true
    device:set_field('client_thread', false)
    init_mqtt(device)

  else
    device:emit_event(cap_status.status('Not Subscribed'))
  end
  
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

  if not device.device_network_id:find('Master', 1, 'plaintext') then

    local dtype = device.device_network_id:match('MQTT_(.+)_+')

    if dtype == 'Switch' then
      device:emit_event(capabilities.switch.switch('off'))
    elseif dtype == 'Dimmer' then
      device:emit_event(capabilities.switchLevel.level(0))
      device:emit_event(capabilities.switch.switch('off'))
    elseif dtype == 'Contact' then
      device:emit_event(capabilities.contactSensor.contact('closed'))
    elseif dtype == 'Motion' then
      device:emit_event(capabilities.motionSensor.motion('inactive'))
    elseif dtype == 'Button' then
      local supported_values =  {
                                  capabilities.button.button.pushed.NAME,
                                  capabilities.button.button.held.NAME,
                                  capabilities.button.button.double.NAME,
                                  capabilities.button.button.pushed_3x.NAME,
                                }
      device:emit_event(capabilities.button.supportedButtonValues(supported_values))
    elseif dtype == 'Alarm' then
      device:emit_event(capabilities.alarm.alarm('off'))
      
    elseif dtype == 'Acceleration' then
      device:emit_event(capabilities.accelerationSensor.acceleration('inactive'))
    elseif dtype == 'Lock' then
      device:emit_event(capabilities.lock.lock('unlocked'))
    elseif dtype == 'Presence' then
      device:emit_event(capabilities.presenceSensor.presence('not present'))
    elseif dtype == 'Sound' then
      device:emit_event(capabilities.soundSensor.sound('not detected'))
      device:emit_event(capabilities.audioVolume.volume(0))
    elseif dtype == 'Water' then
      device:emit_event(capabilities.waterSensor.water('dry'))
    elseif dtype == 'Temperature' then
      device:emit_event(capabilities.temperatureMeasurement.temperature(20))
      device:emit_event(cap_tempset.vtemp({value=20, unit='C'}))
    end

    creator_device:emit_event(cap_createdev.deviceType('Device created'))
    clearcreatemsg_timer = driver:call_with_delay(10, function()
        clearcreatemsg_timer = nil
        creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false }}))
      end
    )

  end
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  log.info ('Device doConfigure lifecycle invoked')

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)

  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")

  if not device.device_network_id:find('Master', 1, 'plaintext') then
    local id, topic = sub.get_subscribed_topic(device)

    if topic then
      sub.unsubscribe(id, topic, true)
    end
  else
    if client then
      sub.unsubscribe_all()
      shutdown_requested = true
      client:disconnect()
    end
    initialized = false
  end

  local devicelist = driver:get_devices()

  if #devicelist == 0 then
    if client then
      shutdown_requested = true
      client:disconnect()
    end
  end

end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end


local function shutdown_handler(driver, event)

  log.info ('*** Driver being shut down ***')

  if client then

    --[[
    for _, topic in pairs(SUBSCRIBED_TOPICS) do
      client:unsubscribe{ topic, callback=function(unsuback)
        log.info("\tUnsubscribed from " .. topic)
      end}
    end
    --]]

    shutdown_requested = true
    client:disconnect()
    creator_device:emit_event(cap_status.status('Driver Shutdown'))
    log.info("Disconnected from MQTT broker")
  end

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  -- Did preferences change?
  if args.old_st_store.preferences then

    local reset_connection = false
    local ip_changed = false
    local uname_changed = false
    local pw_changed = false

    if args.old_st_store.preferences.subTopic ~= device.preferences.subTopic then
      log.info ('Subscribe Topic changed to: ', device.preferences.subTopic)
      local id, topic = sub.get_subscribed_topic(device)
      if topic then
        sub.unsubscribe(id, topic)
        device:emit_event(cap_status.status('Un-Subscribed'))
      end
      
      sub.subscribe_topic(device)
      
    elseif args.old_st_store.preferences.userid ~= device.preferences.userid then
      uname_changed = true
    elseif args.old_st_store.preferences.password ~= device.preferences.password then
      pw_changed = true
    elseif args.old_st_store.preferences.broker ~= device.preferences.broker then
      log.info ('Broker URI changed to: ', device.preferences.broker)
      ip_changed = true
    end
    
    if ip_changed or uname_changed or pw_changed then
      if device.preferences.broker ~= '192.168.1.xxx' then
        init_mqtt(device)
      end
    end

  end
end


-- Create Primary Creator Device
local function discovery_handler(driver, _, should_continue)

  if not initialized then

    log.info("Creating MQTT Creator device")

    local MFG_NAME = 'SmartThings Community'
    local MODEL = 'MQTTCreatorV1'
    local VEND_LABEL = 'MQTT Device Creator V1b' --update; change for testing
    local ID = 'MQTTDev_Masterv1'               --change for testing
    local PROFILE = MASTERPROFILE           --update; change for testing

    -- Create master creator device

    local create_device_msg = {
                                type = "LAN",
                                device_network_id = ID,
                                label = VEND_LABEL,
                                profile = PROFILE,
                                manufacturer = MFG_NAME,
                                model = MODEL,
                                vendor_provided_label = VEND_LABEL,
                              }

    assert (driver:try_create_device(create_device_msg), "failed to create creator device")

    log.debug("Exiting device creation")

  else
    log.info ('MQTT Creator device already created')
  end
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("MQTT Devices", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {
    [cap_createdev.ID] = {
      [cap_createdev.commands.setDeviceType.NAME] = cmd.handle_createdevice,
    },
    [cap_refresh.ID] = {
      [cap_refresh.commands.push.NAME] = cmd.handle_refresh,
    },
    [cap_tempset.ID] = {
      [cap_tempset.commands.setvTemp.NAME] = cmd.handle_tempset,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = cmd.handle_switch,
      [capabilities.switch.commands.off.NAME] = cmd.handle_switch,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = cmd.handle_dimmer,
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = cmd.handle_button,
    },
    [capabilities.alarm.ID] = {
      [capabilities.alarm.commands.off.NAME] = cmd.handle_alarm,
      [capabilities.alarm.commands.siren.NAME] = cmd.handle_alarm,
      [capabilities.alarm.commands.strobe.NAME] = cmd.handle_alarm,
      [capabilities.alarm.commands.both.NAME] = cmd.handle_alarm,
    },
    [capabilities.lock.ID] = {
      [capabilities.lock.commands.lock.NAME] = cmd.handle_lock,
      [capabilities.lock.commands.unlock.NAME] = cmd.handle_lock,
    },
    [capabilities.audioVolume.ID] = {
      [capabilities.audioVolume.commands.setVolume.NAME] = cmd.handle_volume,
    },
  }
})

log.info ('MQTT Device Driver V1.2 Started')

thisDriver:run()
