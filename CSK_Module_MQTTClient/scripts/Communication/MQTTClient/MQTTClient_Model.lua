---@diagnostic disable: undefined-global, redundant-parameter, missing-parameter
--*****************************************************************
-- Inside of this script, you will find the module definition
-- including its parameters and functions
--*****************************************************************

--**************************************************************************
--**********************Start Global Scope *********************************
--**************************************************************************

local nameOfModule = 'CSK_MQTTClient'

local mqttClient_Model = {}

-- Check if CSK_UserManagement module can be used if wanted
mqttClient_Model.userManagementModuleAvailable = CSK_UserManagement ~= nil or false

-- Check if CSK_PersistentData module can be used if wanted
mqttClient_Model.persistentModuleAvailable = CSK_PersistentData ~= nil or false

-- Default values for persistent data
-- If available, following values will be updated from data of CSK_PersistentData module (check CSK_PersistentData module for this)
mqttClient_Model.parametersName = 'CSK_MQTTClient_Parameter' -- name of parameter dataset to be used for this module
mqttClient_Model.parameterLoadOnReboot = false -- Status if parameter dataset should be loaded on app/device reboot

-- Load script to communicate with the MQTTClient_Model interface and give access
-- to the MQTTClient_Model object.
-- Check / edit this script to see/edit functions which communicate with the UI
local setMQTTClient_ModelHandle = require('Communication/MQTTClient/MQTTClient_Controller')
setMQTTClient_ModelHandle(mqttClient_Model)

--Loading helper functions if needed
mqttClient_Model.helperFuncs = require('Communication/MQTTClient/helper/funcs')
mqttClient_Model.ethernetPorts = Engine.getEnumValues("EthernetInterfaces") -- Available interfaces of device running the app
mqttClient_Model.ethernetPortsList = mqttClient_Model.helperFuncs.createJsonList(mqttClient_Model.ethernetPorts)

-- Get device type
local typeName = Engine.getTypeName()
if typeName == 'AppStudioEmulator' or typeName == 'SICK AppEngine' then
  mqttClient_Model.deviceType = 'AppEngine'
else
  mqttClient_Model.deviceType = string.sub(typeName, 1, 7)
end

-- Create parameters / instances for this module
mqttClient_Model.isConnected = false

mqttClient_Model.reconnectionTimer = Timer.create() -- Timer to reconnect in case the connection to the broker is lost
mqttClient_Model.reconnectionTimer:setExpirationTime(5000)
mqttClient_Model.reconnectionTimer:setPeriodic(false)

if _G.availableAPIs.specific == true then
  mqttClient_Model.mqttClient = MQTTClient.create()
end

mqttClient_Model.tempSubscriptionTopic = '' -- temporary preset topic to subscribe
mqttClient_Model.tempSubscriptionQOS = 'QOS0' -- temporary preset qos of topic to subscribe

mqttClient_Model.tempPublishEvent = '' -- temporary preset name of event to register to publish its content
mqttClient_Model.tempPublishTopic = '' -- temporary preset topic to publish
mqttClient_Model.tempPublishData = '' -- temporary preset data to publish
mqttClient_Model.tempPublishQOS = 'QOS0' -- temporary preset qos of topic to publish preset data
mqttClient_Model.tempPublishRetain = 'NO_RETAIN' -- temporary preset retain flag of topic to publish preset data

mqttClient_Model.publishEventsFunctions = {} -- Function(s) to use to publish if event was notified

mqttClient_Model.key = '1234567890123456' -- key to encrypt passwords, should be adapted!

mqttClient_Model.messageLog = {} -- keep the latest 100 received messages

mqttClient_Model.styleForUI = 'None' -- Optional parameter to set UI style
mqttClient_Model.version = Engine.getCurrentAppVersion() -- Version of module

-- Parameters to be saved permanently if wanted
mqttClient_Model.parameters = {}
mqttClient_Model.parameters = mqttClient_Model.helperFuncs.defaultParameters.getParameters() -- Load default parameters
mqttClient_Model.parameters.interface = mqttClient_Model.ethernetPorts[1] -- Select first of available ethernet interfaces

if _G.availableAPIs.specific == true then
  mqttClient_Model.parameters.password = Cipher.AES.encrypt('password', mqttClient_Model.key) -- Password if using user credentials
end

--**************************************************************************
--********************** End Global Scope **********************************
--**************************************************************************
--**********************Start Function Scope *******************************
--**************************************************************************

--- Function to react on UI style change
local function handleOnStyleChanged(theme)
  mqttClient_Model.styleForUI = theme
  Script.notifyEvent("MQTTClient_OnNewStatusCSKStyle", mqttClient_Model.styleForUI)
end
Script.register('CSK_PersistentData.OnNewStatusCSKStyle', handleOnStyleChanged)

--- Function to create and notify internal MQTT log messages
local function sendLog()
  local tempLog2Send = ''
  for i=#mqttClient_Model.messageLog, 1, -1 do
    tempLog2Send = tempLog2Send .. mqttClient_Model.messageLog[i] .. '\n'
  end
  Script.notifyEvent('MQTTClient_OnNewLog', tempLog2Send)
end
mqttClient_Model.sendLog = sendLog

--- Function to add new message to internal MQTT log messages
---@param msg string Message
local function addMessageLog(msg)
  table.insert(mqttClient_Model.messageLog, 1, DateTime.getTime() .. ': ' .. msg)
  if #mqttClient_Model.messageLog == 200 then
    table.remove(mqttClient_Model.messageLog, 200)
  end
  sendLog()
end
mqttClient_Model.addMessageLog = addMessageLog

--- Function to react on "OnReceive" event of MQTT client
---@param topic string The topic the message was posted to
---@param data binary The payload data that was received
---@param qos MQTTClient.QOS The Quality of Service level
---@param retain MQTTClient.Retain The message retain flag
local function handleOnReceive(topic, data, qos, retain)

  if mqttClient_Model.parameters.logAllMessages then
    addMessageLog('[Topic]: ' .. topic .. ', [Data]: ' .. tostring(data) .. ', [QoS]: ' .. qos .. ', [Retain]: ' .. retain)
  end

  if mqttClient_Model.parameters.forwardReceives then
    Script.notifyEvent('MQTTClient_OnReceive', topic, data, qos, retain)
    Script.notifyEvent('MQTTClient_OnReceiveFullString', topic .. ';' .. tostring(data) .. ';' .. qos .. ';' .. retain)
  end
end
if _G.availableAPIs.default and _G.availableAPIs.specific == true then
  MQTTClient.register(mqttClient_Model.mqttClient, 'OnReceive', handleOnReceive)
end

local function publish(topic, data, qos, retain)
  if mqttClient_Model.isConnected then
    local suc = MQTTClient.publish(mqttClient_Model.mqttClient, mqttClient_Model.parameters.topicPrefix .. topic, tostring(data), qos, retain)
    if suc then
      _G.logger:fine(nameOfModule .. ": Publish data '" .. tostring(data) .. "' to topic '" .. mqttClient_Model.parameters.topicPrefix .. topic .. "' with QoS '" .. qos .. "' and '" .. retain .. "'")
      if mqttClient_Model.parameters.logAllMessages then
        addMessageLog("Publish data '" .. tostring(data) .. "' to topic '" .. mqttClient_Model.parameters.topicPrefix .. topic .. "' with QoS '" .. qos .. "' and '" .. retain .. "'")
      end
    end
  else
    _G.logger:info(nameOfModule .. ": Not able to publish data as broker is not connected.")
  end
end
Script.serveFunction('CSK_MQTTClient.publish', publish)
mqttClient_Model.publish = publish

--- Function to subscribe to a topic on a MQTT broker
---@param topicFilter string The topic which to subscribe to.
---@param qos string Quality of Service level. Default is QOS0
local function subscribe(topicFilter, qos)
  _G.logger:fine(nameOfModule .. ": Subscribe to topic '" .. topicFilter .. "' with QOS '" .. tostring(qos) .. "'")
  MQTTClient.subscribe(mqttClient_Model.mqttClient, topicFilter, qos)
end
mqttClient_Model.subscribe = subscribe

--- Function to subscribe to all configured topics
local function subscripeToAllTopics()
  for key, value in pairs(mqttClient_Model.parameters.subscriptions) do
    subscribe(key, value)
  end
end
mqttClient_Model.subscripeToAllTopics = subscripeToAllTopics

--- Function to react on "OnConnected" event of MQTT client
local function handleOnConnected()
  _G.logger:info(nameOfModule .. ": Connected to MQTT broker.")
  Script.notifyEvent('MQTTClient_OnNewConnectionStatus', "Connected to MQTT Broker")
  addMessageLog('Connected to MQTT broker.')
  mqttClient_Model.reconnectionTimer:stop()
  mqttClient_Model.isConnected = true
  Script.notifyEvent("MQTTClient_OnNewStatusCurrentlyConnected", mqttClient_Model.isConnected)
  if mqttClient_Model.parameters.useBirthMessage then
    publish(mqttClient_Model.parameters.birthMessageTopic, mqttClient_Model.parameters.birthMessageData, mqttClient_Model.parameters.birthMessageQOS, mqttClient_Model.parameters.birthMessageRetain)
    _G.logger:info(nameOfModule .. ": Sent birth message to broker")
  end
  subscripeToAllTopics()
end
if _G.availableAPIs.default and  _G.availableAPIs.specific == true then
  MQTTClient.register(mqttClient_Model.mqttClient, 'OnConnected', handleOnConnected)
end

--- Function to react on "OnDisconnected" event of MQTT client
local function handleOnDisconnected()
  _G.logger:info(nameOfModule .. ": Disconnected from MQTT broker.")
  Script.notifyEvent('MQTTClient_OnNewConnectionStatus', 'Disabled')
  addMessageLog('Disconnected from MQTT broker.')
  if mqttClient_Model.parameters.connect == true then
    MQTTClient.connect(mqttClient_Model.mqttClient, mqttClient_Model.parameters.connectionTimeout)
    if mqttClient_Model.mqttClient:isConnected() == false then
      addMessageLog("Disconnected from MQTT broker, starting reconnection timer")
      mqttClient_Model.reconnectionTimer:start()
    end
  end
  mqttClient_Model.isConnected = false
  Script.notifyEvent("MQTTClient_OnNewStatusCurrentlyConnected", mqttClient_Model.isConnected)
end
if _G.availableAPIs.default and _G.availableAPIs.specific == true then
  MQTTClient.register(mqttClient_Model.mqttClient, 'OnDisconnected', handleOnDisconnected)
end

--- Function to reconnect to broker if the connection is lost
local function handleOnReconnectionTimerExpired()
  if mqttClient_Model.parameters.connect == true then
    MQTTClient.connect(mqttClient_Model.mqttClient, mqttClient_Model.parameters.connectionTimeout)
    if mqttClient_Model.mqttClient:isConnected() == false then
      _G.logger:info(nameOfModule .. ": Reconnection trial to MQTT Broker failed.")
      Script.notifyEvent('MQTTClient_OnNewConnectionStatus', "Reconnection trial failed, trying again in 5s")
      addMessageLog("Reconnection trial failed, trying again in 5s")
      mqttClient_Model.reconnectionTimer:start()
    end
  end
end
mqttClient_Model.reconnectionTimer:register('OnExpired', handleOnReconnectionTimerExpired)

--- Function to reset the MQTTClient
local function recreateMQTTClient()
  Script.releaseObject(mqttClient_Model.mqttClient)
  mqttClient_Model.mqttClient = MQTTClient.create()
  MQTTClient.register(mqttClient_Model.mqttClient, 'OnReceive', handleOnReceive)
  MQTTClient.register(mqttClient_Model.mqttClient, 'OnConnected', handleOnConnected)
  MQTTClient.register(mqttClient_Model.mqttClient, 'OnDisconnected', handleOnDisconnected)
end
mqttClient_Model.recreateMQTTClient = recreateMQTTClient

--*************************************************************************
--********************** End Function Scope *******************************
--*************************************************************************

return mqttClient_Model
