% ========================================================================
%> ndots Newsome style dots
%> UNFINISHED
% ========================================================================
classdef ndotsStimulus < baseStimulus
	properties
		family = 'ndots'
		type = 'simple'
		% the size of dots in the kinetogram (pixels)
		dotSize = 3
		% the shape for all dots (integer, where 0 means filled square, 1
		% means filled circle, and 2 means filled circle with high-quality
		% anti-aliasing)
		shape = 1
		% percentage of dots that carry the intended motion signal
		coherence = 1
		% density of dots in the kinetogram (dots per degree-visual-angle^2
		% per second)
		density = 200
		% when direction is an array, the relative frequency of each
		% direction (the pdf).  If directionWeights is incomplete, defaults
		% to equal weights.
		directionWeights = 1
		% diameter
		diameter = 5
		% fraction of diameter that determines the width of the field of
		% moving dots.  When fieldScale > 1, some dots will be hidden
		% behind the aperture.
		fieldScale = 1.1
		% width of angular error to add to each dot's motion (degrees)
		drunkenWalk = 0
		% number disjoint sets of dots to interleave frame-by-frame
		interleaving = 1
		% how to move coherent dots: as one rigid unit (true), or each dot
		% independently (false)
		isMovingAsHerd = true
		% how to move non-coherent dots: by replotting from scratch (true),
		% or by local increments (false)
		isFlickering = false
		% how to move dots near the edges: by wrapping to the other side
		% (true), or by replotting from scratch (false)
		isWrapping = true
		% how to pick coherent dots: favoring recently non-coherent dots
		% (true), or indiscriminately (false)
		isLimitedLifetime = false
		% show mask or not?
		mask = true
		%mask GL modes
		msrcMode = 'GL_SRC_ALPHA'
		mdstMode = 'GL_ONE_MINUS_SRC_ALPHA'
	end
	
	properties (SetAccess = private, GetAccess = public)
		% number of dots in the kinetogram, includes all interleaving
		% frames.
		nDots
		% 2xn matrix of dot x and y coordinates, (normalized units, from
		% top-left of kinetogram)
		normalizedXY
		% scale factor from kinetogram normalized units to pixels
		pixelScale
		% 2xn matrix of dot x and y coordinates, (pixels, from top-left of
		% kinetogram)
		pixelXY
		% center of the kinetogram (pixels, from the top-left of the
		% window)
		pixelOrigin
		% Psychtoolbox Screen texture index for the dot field aperture mask
		maskTexture
		% [x,y,x2,y2] rect, where to draw the dot field aperture mask,
		% (pixels, from the top-left of the window)
		maskDestinationRect
		% [x,y,x2,y2] rect, spanning the entire dot field aperture mask,
		% (pixels, from the top-left of the window)
		maskSourceRect
		% lookup table to pick random dot direction by directionWeights
		directionCDFInverse
		% resolution of directionCDFInverse
		directionCDFSize = 1e3
		% counter to keep track of interleaving frames
		frameNumber = 0
		% logical array to select dots for a frame
		frameSelector
		% count of how many consecutive frames each dot has moved
		% coherently
		dotLifetimes
		% radial step size for dots moving by local increments (normalized
		% units)
		deltaR
		winRect
	end
	
	properties (SetAccess = private, GetAccess = private)
		srcMode = 'GL_ONE'
		dstMode = 'GL_ZERO'
		allowedProperties='^(type|speed|density|dotSize|angle|coherence|shape|kill)$';
		ignoreProperties='pixelXY|pixelOrigin|deltaR|frameNumber|frameSelector|dotLifetimes|nDots|normalizedXY|pixelScale|maskTexture|maskDestinationRect|maskSourceRect'
	end
	
	methods
		% ===================================================================
		%> @brief Class constructor
		%>
		%> More detailed description of what the constructor does.
		%>
		%> @param args are passed as a structure of properties which is
		%> parsed.
		%> @return instance of class.
		% ===================================================================
		function obj = ndotsStimulus(varargin)
			%Initialise for superclass, stops a noargs error
			if nargin == 0
				varargin.family = 'ndots';
				varargin.colour = [1 1 1 1];
			end
			
			obj=obj@baseStimulus(varargin); %we call the superclass constructor first
			
			if nargin>0
				obj.parseArgs(varargin, obj.allowedProperties);
			end
			
			obj.ignoreProperties = ['^(' obj.ignorePropertiesBase '|' obj.ignoreProperties ')$'];
			obj.salutation('constructor','nDots Stimulus initialisation complete');
		end
		
		% ===================================================================
		%> @brief Setup an structure for runExperiment
		%>
		%> @param
		%> @return
		% ===================================================================
		%-------------------Set up our dot matrices----------------------%
		function initialiseDots(obj)
			fr=round(1/obj.ifi);
			% size the dot field and the aperture circle
			fieldWidth = obj.size*obj.fieldScale;
			marginWidth = (obj.fieldScale - 1) * obj.size / 2;
			fieldPixels = ceil(fieldWidth * obj.ppd);
			maskPixels = fieldPixels + obj.dotSize;
			marginPixels = ceil(marginWidth * obj.ppd);
			
			% count dots
			obj.nDots = ceil(obj.density * fieldWidth^2 / fr);
			obj.frameSelector = false(1, obj.nDots);
			obj.dotLifetimes = zeros(1, obj.nDots);
			
			% account for speed as step per interleaved frame
			obj.deltaR = obj.speed / obj.size ...
				* (obj.interleaving / fr);
			
			% account for pixel real estate
			obj.pixelScale = fieldPixels;
			obj.pixelOrigin(1) = obj.winRect(3)/2 ...
				+ (obj.xPosition * obj.ppd) - fieldPixels/2;
			obj.pixelOrigin(2) = obj.winRect(4)/2 ...
				- (obj.yPosition * obj.ppd) - fieldPixels/2;
			
			obj.maskSourceRect = [0 0, maskPixels, maskPixels];
			obj.maskDestinationRect = obj.maskSourceRect ...
				+ obj.pixelOrigin([1 2 1 2]) - obj.dotSize/2;
			
			% build a Psychtoolbox Screen texture to mask the dots
			%   a large rectangle for the entire dots field
			%   with a hole in the middle for the dots viewing aperture
			center = exp(linspace(-1, 1, maskPixels).^2);
			field = center'*center;
			threshold = center(marginPixels);
			aperture = field > threshold;
			mask = zeros(maskPixels, maskPixels, 4);
			mask(:,:,1) = obj.backgroundColour(1);
			mask(:,:,2) = obj.backgroundColour(2);
			mask(:,:,3) = obj.backgroundColour(3);
			mask(:,:,4) = aperture.*1;
			obj.maskTexture = Screen('MakeTexture', ...
				obj.win, ...
				mask);
			
			% build a lookup table to pick weighted directions from a
			% uniform random variable.
			if ~isequal(size(obj.directionWeights), size(obj.angle))
				obj.directionWeights = ones(1, length(obj.angle));
			end
			
			directionCDF = cumsum(obj.directionWeights) ...
				/ sum(obj.directionWeights);
			obj.directionCDFInverse = ones(1, obj.directionCDFSize);
			probs = linspace(0, 1, obj.directionCDFSize);
			for ii = 1:obj.directionCDFSize
				nearest = find(directionCDF >= probs(ii), 1, 'first');
				obj.directionCDFInverse(ii) = obj.angle(nearest);
			end
			
			% pick random start positions for all dots
			obj.normalizedXY = rand(2, obj.nDots);
		end
		
		% ===================================================================
		%> @brief Setup an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return
		% ===================================================================
		function setup(obj,rE)
			
			if exist('rE','var')
				obj.ppd=rE.ppd;
				obj.ifi=rE.screenVals.ifi;
				obj.xCenter=rE.xCenter;
				obj.yCenter=rE.yCenter;
				obj.win=rE.win;
				obj.winRect = rE.winRect;
				obj.srcMode=rE.srcMode;
				obj.dstMode=rE.dstMode;
				obj.backgroundColour = rE.backgroundColour;
				clear rE
			end
			
			fn = fieldnames(ndotsStimulus);
			for j=1:length(fn)
				if isempty(obj.findprop([fn{j} 'Out'])) && isempty(regexp(fn{j},obj.ignoreProperties, 'once')) %create a temporary dynamic property
					p=obj.addprop([fn{j} 'Out']);
					p.Transient = true;%p.Hidden = true;
					if strcmp(fn{j},'size');p.SetMethod = @setsizeOut;end
					if strcmp(fn{j},'dotSize');p.SetMethod = @setdotSizeOut;end
					if strcmp(fn{j},'xPosition');p.SetMethod = @setxPositionOut;end
					if strcmp(fn{j},'yPosition');p.SetMethod = @setyPositionOut;end
				end
				if isempty(regexp(fn{j},obj.ignoreProperties, 'once'))
					obj.([fn{j} 'Out']) = obj.(fn{j}); %copy our property value to our tempory copy
				end
			end
			
			if isempty(obj.findprop('doDots'));p=obj.addprop('doDots');p.Transient = true;end
			if isempty(obj.findprop('doMotion'));p=obj.addprop('doMotion');p.Transient = true;end
			if isempty(obj.findprop('doDrift'));p=obj.addprop('doDrift');p.Transient = true;end
			if isempty(obj.findprop('doFlash'));p=obj.addprop('doFlash');p.Transient = true;end
			obj.doDots = [];
			obj.doMotion = [];
			obj.doDrift = [];
			obj.doFlash = [];
			
			if isempty(obj.findprop('xTmp'));p=obj.addprop('xTmp');p.Transient = true;end
			if isempty(obj.findprop('yTmp'));p=obj.addprop('yTmp');p.Transient = true;end
			obj.xTmp = obj.xPositionOut; %xTmp and yTmp are temporary position stores.
			obj.yTmp = obj.yPositionOut;
			
			obj.initialiseDots();
			obj.computeNextFrame();
			
		end
		
		% ===================================================================
		%> @brief Update an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function update(obj)
			obj.initialiseDots();
			obj.computeNextFrame();
			obj.tick = 1;
		end
		
		% ===================================================================
		%> @brief Draw an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function draw(obj)
			if obj.isVisible == true
				if obj.mask == true
					Screen('BlendFunction', obj.win, obj.msrcMode, obj.mdstMode);
					Screen('DrawDots', ...
						obj.win, ...
						obj.pixelXY(:,obj.frameSelector), ...
						obj.dotSize, ...
						obj.colour, ...
						obj.pixelOrigin, ...
						obj.shape);
					Screen('DrawTexture', obj.win, obj.maskTexture, obj.maskSourceRect, obj.maskDestinationRect);
					Screen('BlendFunction', obj.win, obj.srcMode, obj.dstMode);
				else
					Screen('DrawDots', ...
						obj.win, ...
						obj.pixelXY(:,obj.frameSelector), ...
						obj.dotSize, ...
						obj.colour, ...
						obj.pixelOrigin, ...
						obj.shape);
				end
			end
		end
		
		% ===================================================================
		%> @brief Animate an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function animate(obj)
			computeNextFrame(obj);
			obj.tick = obj.tick + 1;
		end
		
		% ===================================================================
		%> @brief Reset an structure for runExperiment
		%>
		%> @param rE runExperiment object for reference
		%> @return stimulus structure.
		% ===================================================================
		function reset(obj)
			obj.removeTmpProperties;
		end
		
	end%---END PUBLIC METHODS---%
	
	%=======================================================================
	methods ( Access = private ) %-------PRIVATE METHODS-----%
	%=======================================================================
		
		% ===================================================================
		%> @brief Compute dot positions for the next frame of animation.
		%>
		% ===================================================================
		function computeNextFrame(obj)
			% cache some properties as local variables because it's faster
			nFrames = obj.interleaving;
			frame = obj.frameNumber;
			frame = 1 + mod(frame, nFrames);
			obj.frameNumber = frame;
			
			thisFrame = obj.frameSelector;
			thisFrame(thisFrame) = false;
			thisFrame(frame:nFrames:end) = true;
			obj.frameSelector = thisFrame;
			nFrameDots = sum(thisFrame);
			
			% pick coherent dots
			cohSelector = false(size(thisFrame));
			cohCoinToss = rand(1, nFrameDots) < obj.coherence;
			nCoherentDots = sum(cohCoinToss);
			nNonCoherentDots = nFrameDots - nCoherentDots;
			lifetimes = obj.dotLifetimes;
			if obj.isLimitedLifetime
				% would prefer not to call sort
				%   should be able to do accounting as we go
				[frameSorted, frameOrder] = ...
					sort(lifetimes(thisFrame));
				isInFrameAndShortLifetime = false(1, nFrameDots);
				isInFrameAndShortLifetime(frameOrder(1:nCoherentDots)) = true;
				cohSelector(thisFrame) = isInFrameAndShortLifetime;
				
			else
				cohSelector(thisFrame) = cohCoinToss;
			end
			lifetimes(cohSelector) = ...
				lifetimes(cohSelector) + 1;
			
			% account for non-coherent dots
			nonCohSelector = false(size(thisFrame));
			nonCohSelector(thisFrame) = true;
			nonCohSelector(cohSelector) = false;
			lifetimes(nonCohSelector) = 0;
			obj.dotLifetimes = lifetimes;
			
			% pick motion direction(s) for coherent dots
			if obj.isMovingAsHerd
				nDirections = 1;
			else
				nDirections = nCoherentDots;
			end
			
			if numel(obj.angle) == 1
				% use the one constant direction
				degrees = obj.angle(1) * ones(1, nDirections);
				
			else
				% pick from the direction distribution
				CDFIndexes = 1 + ...
					floor(rand(1, nDirections)*(obj.directionCDFSize));
				degrees = obj.directionCDFInverse(CDFIndexes);
			end
			
			if obj.drunkenWalk > 0
				% jitter the direction from a uniform distribution
				degrees = degrees + ...
					obj.drunkenWalk * (rand(1, nDirections) - .5);
			end
			
			% move the coherent dots
			XY = obj.normalizedXY;
			R = obj.deltaR;
			radians = pi*degrees/180;
			deltaX = R*cos(radians);
			deltaY = R*sin(radians);
			XY(1,cohSelector) = XY(1,cohSelector) + deltaX;
			XY(2,cohSelector) = XY(2,cohSelector) - deltaY;
			
			% move the non-coherent dots
			if obj.isFlickering
				XY(:,nonCohSelector) = rand(2, nNonCoherentDots);
				
			else
				radians = 2*pi*rand(1, nNonCoherentDots);
				deltaX = R*cos(radians);
				deltaY = R*sin(radians);
				XY(1,nonCohSelector) = XY(1,nonCohSelector) + deltaX;
				XY(2,nonCohSelector) = XY(2,nonCohSelector) - deltaY;
			end
			
			% keep dots from moving out of the field
			tooBig = XY > 1;
			tooSmall = XY < 0;
			componentOverrun = tooBig | tooSmall;
			if obj.isWrapping
				% wrap the overrun component
				%   carry the overrun to prevent striping
				XY(tooBig) = XY(tooBig) - 1;
				XY(tooSmall) = XY(tooSmall) + 1;
				
				% randomize the other component
				wrapRands = rand(1, sum(componentOverrun(1:end)));
				XY(componentOverrun([2,1],:)) = wrapRands;
				
			else
				% randomize both components when either overruns
				overrun = any(componentOverrun, 1);
				XY([1,2],overrun) = rand(2, sum(overrun));
			end
			
			obj.normalizedXY = XY;
			obj.pixelXY = XY*obj.pixelScale;
		end
		% ===================================================================
		%> @brief sfOut Set method
		%>
		% ===================================================================
		function setsizeOut(obj,value)
			obj.sizeOut = value * obj.ppd;
		end
		
		% ===================================================================
		%> @brief sfOut Set method
		%>
		% ===================================================================
		function setdotSizeOut(obj,value)
			obj.dotSizeOut = value * obj.ppd;
		end
		
		% ===================================================================
		%> @brief xPositionOut Set method
		%>
		% ===================================================================
		function setxPositionOut(obj,value)
			obj.xPositionOut = obj.xCenter + (value * obj.ppd);
		end
		
		% ===================================================================
		%> @brief yPositionOut Set method
		%>
		% ===================================================================
		function setyPositionOut(obj,value)
			obj.yPositionOut = obj.yCenter + (value * obj.ppd);
		end
	end
	
	
end

