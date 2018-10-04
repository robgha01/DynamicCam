---------------
-- CONSTANTS --
---------------
local VIEW_TRANSITION_SPEED = 10; -- TODO: remove this awful thing


-------------
-- GLOBALS --
-------------
assert(DynamicCam);
DynamicCam.Camera = DynamicCam:NewModule("Camera", "AceTimer-3.0", "AceHook-3.0");


------------
-- LOCALS --
------------
local Camera = DynamicCam.Camera;
local parent = DynamicCam;
local _;

local zoom = {
	value = 0,
	confident = false,

	set = nil,

	action = nil,
	time = nil,
	continousSpeed = 1,

	timer = nil,
	incTimer = nil,
	oldSpeed = nil,
	oldMaxDistance = nil,
}

local rotation = {
	action = nil,
	time = nil,
	speed = 0,
	timer = nil,
};

local nameplateRestore = {};
local function RestoreNameplates()
	-- restore nameplates if they need to be restored
	if (not InCombatLockdown()) then
		for k,v in pairs(nameplateRestore) do
			SetCVar(k, v);
		end
		nameplateRestore = {};
	end
end


----------
-- CORE --
----------
function Camera:OnInitialize()
	-- hook camera functions to figure out wtf is happening
	self:Hook("CameraZoomIn", true);
	self:Hook("CameraZoomOut", true);

	self:Hook("MoveViewInStart", true);
	self:Hook("MoveViewInStop", true);
	self:Hook("MoveViewOutStart", true);
	self:Hook("MoveViewOutStop", true);


	self:Hook("SetView", "SetView", true);
	self:Hook("ResetView", "ResetView", true);
	self:Hook("SaveView", "SaveView", true);

	self:Hook("PrevView", "ResetZoomVars", true)
	self:Hook("NextView", "ResetZoomVars", true)
end


-----------
-- CVARS --
-----------
local function GetMaxZoomFactor()
	return tonumber(GetCVar("cameradistancemaxfactor"));
end

local function SetMaxZoomFactor(value)
	SetCVar("cameradistancemaxfactor", value);
end

local function GetMaxZoom()
	return 15*GetMaxZoomFactor();
end

local function SetMaxZoom(value)
    if (value) then
        parent:DebugPrint("SetMaxZoom:", value);
		SetMaxZoomFactor(math.max(1, math.min(2.6, value/15)));
    end
end

local function GetZoomSpeed()
	return tonumber(GetCVar("cameradistancemovespeed"));
end

local function SetZoomSpeed(value)
    	parent:DebugPrint("SetZoomSpeed:", value);
	SetCVar("cameradistancemovespeed", math.min(50,value));
end

local function GetYawSpeed()
	return tonumber(GetCVar("cameraYawMoveSpeed"));
end


---------------------
-- LOCAL FUNCTIONS --
---------------------

local function GetEstimatedZoomTime(increments)
	return increments/GetZoomSpeed();
end

local function GetEstimatedZoomSpeed(increments, time)
	return math.min(50, (increments/time));
end

local function GetEstimatedRotationSpeed(degrees, time)
	-- (DEGREES) / (SECONDS) = SPEED
	-- TODO: compensate for the smoothing factors?
	return (((degrees)/time)/GetYawSpeed());
end

local function GetEstimatedRotationTime(degrees, speed)
	-- (DEGREES) / (SECONDS) = SPEED
	-- (DEGREES) / (SPEED) = SECONDS
	-- TODO: compensate for the smoothing factors?
	return ((degrees)/(speed * GetYawSpeed()));
end

local function GetEstimatedRotationDegrees(time, speed)
	-- (DEGREES) / (SECONDS) = SPEED
	-- DEGREES = SPEED * SECONDS
	-- TODO: compensate for the smoothing factors?
	return (time * speed * GetYawSpeed());
end


-----------
-- HOOKS --
-----------
local function CameraZoomFinished(restore)
	parent:DebugPrint("Finished zooming");

	-- restore oldSpeed if it exists
    if (restore and zoom.oldSpeed) then
        SetZoomSpeed(zoom.oldSpeed);
        zoom.oldSpeed = nil;
    end

	zoom.action = nil;
	zoom.time = nil;
	zoom.set = nil;
end

function Camera:CameraZoomIn(...)
	self:CameraZoom("in", ...);
end

function Camera:CameraZoomOut(...)
	self:CameraZoom("out", ...);
end

function Camera:CameraZoom(direction, increments, automated)
	local zoomMax = GetMaxZoom();
	increments = increments or 1;
	
	-- check if we were continously zooming before and stop tracking it if we were
	if (zoom.action == "continousIn") then
		self:MoveViewInStop();
	elseif (zoom.action == "continousOut") then
		self:MoveViewOutStop();
	end

	if direction == "in" then
		-- check to see if we were previously zooming in and we're not done yet
		if (zoom.time and zoom.time >= GetTime()) then
			-- canceled zooming in, get the time left and guess how much distance we didn't cover
			local timeLeft = zoom.time - GetTime();

			-- (seconds) * (yards/second) = yards
			zoom.value = zoom.value + (timeLeft * GetZoomSpeed());

			self:LoseConfidence();
			zoom.action = nil;
			zoom.time = nil;
		end

		-- set the zoom variable
		if (zoom.confident) then
			--we know where we are, then set the zoom, zoom can only go to zoomMax
			local oldZoom = zoom.value;
			zoom.value = math.min(zoom.value + increments, zoomMax);

			if (zoom.value >= zoomMax) then
				increments = zoomMax - oldZoom;
			end
		else
			-- we don't know where we are, just assume that we're not zooming out further than we can go
			zoom.value = zoom.value + increments;

			-- we've now zoomed out past the max, so we can assume that we're at max
			if (zoom.value >= zoomMax) then
				zoom.value = zoomMax;
				zoom.confident = true;
				increments = 0;
			end
		end
	elseif direction == "out" then
		-- check to see if we were previously zooming out and we're not done yet
		if (zoom.time and zoom.time >= GetTime()) then
			-- canceled zooming out, get the time left and guess how much distance we didn't cover
			local timeLeft = zoom.time - GetTime();

			-- (seconds) * (yards/second) = yards
			zoom.value = zoom.value - (timeLeft * GetZoomSpeed());

			self:LoseConfidence();
			zoom.action = nil;
			zoom.time = nil;
		end

		-- set the zoom variable
		if (zoom.confident) then
			-- we know where we are, then set the zoom, zoom can only go to 0
			local oldZoom = zoom.value;
			zoom.value = math.max(zoom.value - increments, 0);

			if (zoom.value < 0.5) then
				zoom.value = 0;
				increments = oldZoom;
			end
		else
			-- we don't know where we are, just assume that we're not zooming in further than we can go
			zoom.value = zoom.value - increments;

			-- we've now zoomed in past the max, so we can assume that we're at 0
			if (zoom.value <= -zoomMax) then
				zoom.value = 0;
				zoom.confident = true;
				increments = 0;
			end
		end
	end

	-- check if we were going in the opposite direction
	if (zoom.action and zoom.action ~= direction) then
		-- remove set point, since it doesn't matter anymore, since we canceled
		CameraZoomFinished(true);
	end

	-- set zoom.set
	local setZoom;
	if (zoom.action and zoom.action == direction and zoom.set) then
		setZoom = zoom.set;
	else
		setZoom = self:GetZoom();
	end
	
	if (direction == "in") then
		-- zooming in
		zoom.set = math.max(0, setZoom - increments);
	elseif (direction == "out") then
		-- zooming out
		zoom.set = math.min(zoomMax, setZoom + increments);
	end

	-- set zoom done time
	-- (yard) / (yards/second) = seconds
	local difference = math.abs(self:GetZoom() - zoom.set);
	local timeToZoom = GetEstimatedZoomTime(difference);
	local reactiveZoom = parent.db.profile.reactiveZoom;
	if (difference > 0) then
		zoom.action = direction;
		
		if (parent.db.profile.enabled and reactiveZoom.enabled and not automated) then
			-- add increments always
			if (reactiveZoom.addIncrementsAlways > 0) then
				if (direction == "in") then
					CameraZoomIn(reactiveZoom.addIncrementsAlways, true);
				elseif (direction == "out") then
					CameraZoomOut(reactiveZoom.addIncrementsAlways, true);
				end
			end

			-- if manual zoom, then do additional increments
			if (reactiveZoom.addIncrements > 0) then
				if (difference > reactiveZoom.incAddDifference) then
					if (direction == "in") then
						CameraZoomIn(reactiveZoom.addIncrements, true);
					elseif (direction == "out") then
						CameraZoomOut(reactiveZoom.addIncrements, true);
					end
				end
			end

			-- have to recalculate, since we're zooming more
			difference = math.abs(self:GetZoom() - zoom.set);
			timeToZoom = GetEstimatedZoomTime(difference);

			-- if we're going to take longer than time, speed it up
			if (timeToZoom > reactiveZoom.maxZoomTime) then
				local speed = GetEstimatedZoomSpeed(difference, reactiveZoom.maxZoomTime);
				
				if (speed > GetZoomSpeed()) then
					zoom.oldSpeed = zoom.oldSpeed or GetZoomSpeed();
					SetZoomSpeed(speed);
				end

				timeToZoom = GetEstimatedZoomTime(difference);
			end
		end

		-- set a timer for when it finishes
		if (incTimer) then
			self:CancelTimer(incTimer);
			incTimer = nil;
		end

		zoom.time = GetTime() + timeToZoom;
		incTimer = self:ScheduleTimer(CameraZoomFinished, timeToZoom, not automated);
	end

	parent:DebugPrint(automated and "Automated" or "Manual", "Zoom", direction, "increments:", increments, "diff:", difference, "new zoom level:", zoom.set, "time:", timeToZoom);
end

function Camera:MoveViewInStart(speed)
	zoom.action = "continousIn";
	zoom.time = GetTime();

	if (speed) then
		zoom.continousSpeed = speed;
	else
		zoom.continousSpeed = 1;
	end
end

function Camera:MoveViewInStop()
	if (zoom.action == "continousIn") then
		zoom.action = nil;
		zoom.time = nil;
	end
end

function Camera:MoveViewOutStart(speed)
	zoom.action = "continousOut";
	zoom.time = GetTime();

	if (speed) then
		zoom.continousSpeed = speed;
	else
		zoom.continousSpeed = 1;
	end
end

function Camera:MoveViewOutStop()
	if (zoom.action == "continousOut") then
		zoom.action = nil;
		zoom.time = nil;
	end
end

function Camera:SetView(view)
	-- restore zoom values from saves view if we can,
	if (parent.db.global.savedViews[view]) then
		zoom.value = parent.db.global.savedViews[view];
		viewTimer = self:ScheduleTimer(function() zoom.confident = true; end, VIEW_TRANSITION_SPEED);
	else
		self:ResetZoomVars();
	end
end

function Camera:ResetView(view)
	parent.db.global.savedViews[view] = nil;
end

function Camera:SaveView(view)
	-- if we know where we are, then save the zoom level to be restored when the view is set
	if (zoom.confident) then
		parent.db.global.savedViews[view] = zoom.value;

		if (view ~= 1) then
			parent:Print("Saved view", view, "with absolute zoom.");
		end
	else
		if (view ~= 1) then
			parent:Print("Saved view", view, "but couldn't save zoom level!");
		end
	end
end

function Camera:ResetZoomVars()
	self:LoseConfidence();
end

--------------------
-- CAMERA ACTIONS --
--------------------
function Camera:IsPerformingAction()
	return (self:IsZooming() or self:IsRotating());
end

function Camera:StopAllActions()
	if (self:IsZooming()) then
		self:StopZooming();
	end

	if (self:IsRotating()) then
		self:StopRotating();
	end
end


------------------
-- ZOOM ACTIONS --
------------------
function Camera:PrintCameraVars()
	parent:Print("Zoom info:", "value:", zoom.value, ((zoom.time and (zoom.time - GetTime() > 0)) and (zoom.action or "no action").." "..(zoom.time - GetTime()) or ""), (zoom.confident and "" or "not confident"));
end

function Camera:ResetConfidence(value)
	ResetView(1);
	SetView(1);
	SetView(1);

	zoom.value = 0;
	zoom.confident = true;

	self:SetZoom(value, .5, true);
end

function Camera:LoseConfidence()
    zoom.value = 0;
    zoom.confident = false;
end

function Camera:IsConfident()
	return zoom.confident;
end

function Camera:IsZooming()
    local ret = false;

    -- has an active action running
	if (zoom.action and zoom.time) then
		if (zoom.time > GetTime()) then
			ret = true;
		else
			zoom.time = nil;
		end
    end

    -- has an active timer running
    if (zoom.timer) then
        -- has an active timer running
        parent:DebugPrint("Active timer running, so is zooming")
        ret = true;
	end

	return ret;
end

function Camera:StopZooming()
	-- restore oldMax if it exists
	if (zoom.oldMax) then
		SetMaxZoom(zoom.oldMax);
		zoom.oldMax = nil;
	end

    -- restore oldSpeed if it exists
    if (zoom.oldSpeed) then
        SetZoomSpeed(zoom.oldSpeed);
        zoom.oldSpeed = nil;
    end

	-- has a timer waiting
	if (zoom.timer) then
		-- kill the timer
		self:CancelTimer(zoom.timer);
        parent:DebugPrint("Killing zoom timer!");
        zoom.timer = nil;
	end

	-- restore nameplates if need to
	RestoreNameplates();

	if ((zoom.action == "in" or zoom.action == "in") and zoom.time and (zoom.time > (GetTime() + .25))) then
		-- we're obviously still zooming in from an incremental zoom, cancel it
		CameraZoomOut(0);
		CameraZoomIn(0);
		zoom.action = nil;
		zoom.time = nil;
	elseif (zoom.action == "continousIn") then
		MoveViewInStop();
	elseif (zoom.action == "continousOut") then
		MoveViewOutStop();
	end
end

function Camera:GetZoom()
	-- TODO: check up on
	return zoom.value;
end

function Camera:SetZoom(level, time, timeIsMax)
	if (zoom.confident) then
		-- know where we are, perform just a zoom in or zoom out to level
		local difference = self:GetZoom() - level;

		parent:DebugPrint("SetZoom", level, time, timeIsMax, "difference", difference);

		-- set zoom speed to match time
		if (difference ~= 0) then
			zoom.oldSpeed = zoom.oldSpeed or GetZoomSpeed();
			local speed = GetEstimatedZoomSpeed(math.abs(difference), time);

			if ((not timeIsMax) or (timeIsMax and (speed > zoom.oldSpeed))) then
				SetZoomSpeed(speed);

				local func = function ()
					if (zoom.oldSpeed) then
						SetZoomSpeed(zoom.oldSpeed);
						zoom.oldSpeed = nil;
						zoom.timer = nil;
					end
				end

				zoom.timer = self:ScheduleTimer(func, GetEstimatedZoomTime(math.abs(difference)));
			end
		end

		if (self:GetZoom() > level) then
			CameraZoomIn(difference);
			return true;
		elseif (self:GetZoom() < level) then
			CameraZoomOut(-difference);
			return true;
		end
	else
		parent:DebugPrint("SetZoom with not confident zoom");
		
		-- we don't know where we are, so use max zoom trick
		zoom.oldMax = zoom.oldMax or GetMaxZoom();

		-- set max zoom to the level
		SetMaxZoom(level);

		-- zoom out level increments + 1, guarenteeing that we're at the level after zoom
		CameraZoomOut(level+1);

		-- set a timer to restore max zoom and to set confidence
		local func = function ()
			zoom.confident = true;

            if (zoom.oldMax) then
                SetMaxZoom(zoom.oldMax);
                zoom.oldMax = nil;
                zoom.timer = nil;
            end
		end
		zoom.timer = self:ScheduleTimer(func, GetEstimatedZoomTime(level+1));
	end
end

function Camera:ZoomUntil(condition, continousTime, isFitting)
    if (condition) then
        local command, increments, speed = condition(isFitting);

        if (command) then
            if (speed) then
                -- set speed, StopZooming will set it back
                if (speed > GetZoomSpeed()) then
                    zoom.oldSpeed = zoom.oldSpeed or GetZoomSpeed();
                    SetZoomSpeed(speed);
                end
            end

            -- actually zoom in the direction
            if (command == "in") then
                -- if we're not already zooming out, zoom in
                if (not (zoom.action and zoom.action == "out" and zoom.time and zoom.time >= (GetTime() - .1))) then
					CameraZoomIn(increments);
					
					zoom.confident = false; -- TODO: find why nameplate zoom looses track of zoom level
                end
            elseif (command == "out") then
                -- if we're not already zooming in, zoom out
               if (not (zoom.action and zoom.action == "in" and zoom.time and zoom.time >= (GetTime() - .1))) then
					CameraZoomOut(increments);
					
					zoom.confident = false; -- TODO: find why nameplate zoom looses track of zoom level
               end
            elseif (command == "set") then
                if (not (zoom.action and zoom.time and zoom.time >= (GetTime() - .1))) then
                    parent:DebugPrint("Nameplate setting zoom!", increments);
                    self:SetZoom(increments, .5, true); -- constant value here
                end
            end

            -- if the cammand is to wait, just setup the timer
            if (command == "wait") then
                parent:DebugPrint("Waiting on namemplate zoom");
                zoom.timer = self:ScheduleTimer("ZoomUntil", .1, condition, continousTime);
            end

            if (increments) then
                -- set a timer for when this should be called again
                zoom.timer = self:ScheduleTimer("ZoomUntil", GetEstimatedZoomTime(increments)*.75, condition, continousTime, true);
            end

            return true;
        else
            -- the condition is met
            if (zoom.oldSpeed) then
                SetZoomSpeed(zoom.oldSpeed);
                zoom.oldSpeed = nil;
            end

            -- if continously checking, then set the timer for that
            if (continousTime) then
                zoom.timer = self:ScheduleTimer("ZoomUntil", continousTime, condition, continousTime);
			else
				zoom.timer = nil;

				 -- reestablish confidence for non-continous zoom-fit
				if (not zoom.confident) then
					self:SetZoom(zoom.value, .1, true); -- TODO: look at constant value here
				end

				-- restore nameplates if they need to be restored
				RestoreNameplates();
            end

            return;
        end
	end
end


----------------------
-- ZOOM CONVENIENCE --
----------------------
function Camera:ZoomInTo(level, time, timeIsMax)
	if (zoom.confident) then
		-- we know where we are, so check zoom level and only zoom in if we need to
		if (self:GetZoom() > level) then
			return self:SetZoom(level, time, timeIsMax);
		end
	else
		-- not confident or relative, just set to the level
		return self:SetZoom(level, time, timeIsMax);
	end
end

function Camera:ZoomOutTo(level, time, timeIsMax)
	if (zoom.confident) then
		-- we know where we are, so check zoom level and only zoom out if we need to
		if (self:GetZoom() < level) then
			return self:SetZoom(level, time, timeIsMax);
		end
	else
		-- not confident or relative, just set to the level
		return self:SetZoom(level, time, timeIsMax);
	end
end

function Camera:ZoomToRange(minLevel, maxLevel, time, timeIsMax)
	if (zoom.confident) then
		-- we know where we are, so check zoom level and only zoom if we need to
		if (self:GetZoom() < minLevel) then
			return self:SetZoom(minLevel, time, timeIsMax);
		elseif (self:GetZoom() > maxLevel) then
			return self:SetZoom(maxLevel, time, timeIsMax);
		end
	else
		-- not confident or relative, just set to the average
		return self:SetZoom((minLevel+maxLevel)/2, time, timeIsMax);
	end
end

function Camera:FitNameplate(zoomMin, zoomMax, increments, nameplatePosition, sensitivity, speedMultiplier, continously, toggleNameplate)
	parent:DebugPrint("Fitting Nameplate for target");

	local lastSpeed = 0;
	local startTime = GetTime();
	local settleTimeStart;
	-- create a function that returns the zoom direction or nil for stop zooming
	local condition = function(isFitting)
		local nameplate = DynamicCam.TargetNameplate or DynamicCam.LibNameplate:GetNameplateByUnit("target");

		-- we're out of the min and max
		if (zoom.value > zoomMax) then
			return "in", (zoom.value - zoomMax), 20;
		elseif (zoom.value < zoomMin) then
			return "out", (zoomMin - zoom.value), 20;
		end

		-- if the nameplate exists, then adjust
		if (nameplate) then
			--local top = nameplate:GetTop();
			local yCenter = (nameplate:GetTop() + nameplate:GetBottom())/2;
			local screenHeight = GetScreenHeight() * UIParent:GetEffectiveScale();
			local difference = screenHeight - yCenter;
			local ratio = (1 - difference/screenHeight) * 100;
			
			if (isFitting) then
				parent:DebugPrint("Fitting", "Ratio:", ratio, "Bounds:", math.max(50, nameplatePosition - sensitivity/2), math.min(94, nameplatePosition + sensitivity/2));
			else
				parent:DebugPrint("Ratio:", ratio, "Bounds:", math.max(50, nameplatePosition - sensitivity), math.min(94, nameplatePosition + sensitivity));
			end

			if (difference < 40) then
				-- we're at the top, go at top speed
				if ((zoom.value + (increments*4)) <= zoomMax) then
					return "out", increments*4, 14*speedMultiplier;
				end
			elseif (ratio > (isFitting and math.min(94, nameplatePosition + sensitivity/2) or math.min(94, nameplatePosition + sensitivity))) then
				-- we're on screen, but above the target
				if ((zoom.value + increments) <= zoomMax) then
					return "out", increments, 11*speedMultiplier;
				end
			elseif (ratio > 50 and ratio <= (isFitting and math.max(50, nameplatePosition - sensitivity/2) or math.max(50, nameplatePosition - sensitivity))) then
				-- we're on screen, "in front" of the player
				if ((zoom.value - (increments)) >= zoomMin) then
					return "in", increments, 11*speedMultiplier;
				end
			end
		else
			-- nameplate doesn't exist, toggle it on
			if (toggleNameplate and not InCombatLockdown() and not nameplateRestore["nameplateShowAll"]) then
				--nameplateRestore["nameplateShowAll"] = GetCVar("nameplateShowAll");
				nameplateRestore["nameplateShowFriends"] = GetCVar("nameplateShowFriends");
				nameplateRestore["nameplateShowEnemies"] = GetCVar("nameplateShowEnemies");

				-- show nameplates
				--SetCVar("nameplateShowAll", 1);
				if (UnitExists("target")) then
					if (UnitIsFriend("player", "target")) then
						SetCVar("nameplateShowFriends", 1);
					else
						SetCVar("nameplateShowEnemies", 1);
					end
				else
					SetCVar("nameplateShowFriends", 1);
					SetCVar("nameplateShowEnemies", 1);
				end
			end

			-- namemplate doesn't exist, just wait
			return "wait";
		end

		-- if we're not fitting then use the time to establish zoom confidence
		if (not isFitting and not zoom.confident) then
			self:SetZoom(zoom.value, .1, true); -- TODO: look at constant value here
		end

		return nil;
	end

	-- if we're not confident, then just set to min, then ZoomUntil
	if (not zoom.confident) then
		parent:DebugPrint("Zoom fit with no confidence, going to min");
		self:SetZoom(zoomMin, .5, true);
		zoom.timer = self:ScheduleTimer("ZoomUntil", GetEstimatedZoomTime(zoomMin), condition, continously and .75 or nil);
	else
		zoom.timer = self:ScheduleTimer("ZoomUntil", .25, condition, continously and .75 or nil, true);
	end

	return true;
end


--------------------
-- ROTATE ACTIONS --
--------------------
function Camera:IsRotating()
	if (rotation.action) then
		return true;
	end

	return false;
end

function Camera:StopRotating()
	local degrees = 0;
	if (rotation.action == "continousLeft" or rotation.action == "degreesLeft") then
		-- stop rotating
		MoveViewLeftStop();

		-- find the amount of degrees that we rotated for
		degrees = GetEstimatedRotationDegrees(GetTime() - rotation.time, -rotation.speed)
	elseif (rotation.action == "continousRight" or rotation.action == "degreesRight") then
		-- stop rotating
		MoveViewRightStop();

		-- find the amount of degrees that we rotated for
		degrees = GetEstimatedRotationDegrees(GetTime() - rotation.time, rotation.speed)
	end

	if (degrees ~= 0) then
		-- reset rotation variables
		rotation.action = nil;
		rotation.speed = 0;
		rotation.time = nil;
	end

	return degrees;
end

function Camera:StartContinousRotate(speed)
    -- stop rotating if we are already
    if (self:IsRotating()) then
        self:StopRotating();
    end

	if (speed < 0) then
		rotation.action = "continousLeft";
		rotation.speed = -speed;
		rotation.time = GetTime();
		MoveViewLeftStart(rotation.speed);
	elseif (speed > 0) then
		rotation.action = "continousRight";
		rotation.speed = speed;
		rotation.time = GetTime();
		MoveViewRightStart(rotation.speed);
	end
end

function Camera:StartArcRotate(degrees, speed)
	-- TODO: implement

    -- stop rotating if we are already
    if (self:IsRotating()) then
        self:StopRotating();
    end
end

function Camera:RotateDegrees(degrees, transitionTime)
	parent:DebugPrint("RotateDegrees", degrees, transitionTime);
	local speed = GetEstimatedRotationSpeed(degrees, transitionTime);

    -- stop rotating if we are already
    if (self:IsRotating()) then
        self:StopRotating();
    end

	if (speed < 0) then
		-- save rotation variables
		rotation.action = "degreesLeft";
		rotation.speed = -speed;
		rotation.time = GetTime();

		-- start actually rotating
		MoveViewLeftStart(rotation.speed);
	elseif (speed > 0) then
		-- save rotation variables
		rotation.action = "degreesRight";
		rotation.speed = speed;
		rotation.time = GetTime();

		-- start actually rotating
		MoveViewRightStart(speed);
	end

	-- setup a timer to stop the rotation
	if (speed ~= 0) then
		rotation.timer = self:ScheduleTimer("StopRotating", transitionTime);
	end
end


------------------
-- VIEW ACTIONS --
------------------
function Camera:GotoView(view, time, instant, zoomAmount)
    if (not instant) then
        -- TODO: use time and zoomAmount to change view speed

        -- Actually set the view
        SetView(view);
    else
        SetView(view);
        SetView(view);
    end
end
