function sidechain_compressor()

debug = true;
noCompression = false;

frameLength = 256;  % 256 - 2048

sidechainFileR = dsp.AudioFileReader( ...
    'Filename','voice.wav', ...
    'SamplesPerFrame',frameLength);
musicFileR = dsp.AudioFileReader( ...
    'Filename','musicshort.wav', ...
    'SamplesPerFrame',frameLength);
musicFileW = dsp.AudioFileWriter...
   ('out.wav', ...
   'SampleRate', musicFileR.SampleRate);
if (debug)
    deviceWriter = audioDeviceWriter( ...
        'SampleRate',musicFileR.SampleRate, ...
        'Device', 'Default');
end

samplingFreq = musicFileR.SampleRate;
if (samplingFreq ~= 48000) 
    disp('sample freq not supprted');
    return;
end

enableLookAhead = true;
lookAheadTime = 0.2;  % 0 - 0.2
lookAheadSamples = int32(lookAheadTime * samplingFreq);

kneeWidth = 10; % 0 - 20dB
timeAttack = 0.1;  % 0.01 - 0.2
timeRelease = 1;  % 0.1 - 1.0
gainAlphaAttack = exp(-log(9) / (samplingFreq * timeAttack));
gainAlphaRelease = exp(-log(9) / (samplingFreq * timeRelease));
powerAlphaAttack = exp(-log(9) / (samplingFreq/frameLength * 0.1));
powerAlphaRelease = exp(-log(9) / (samplingFreq/frameLength * 1));

sidechainPowerThreshold = -40;  % -40 - -20
thresholdOffset = 30;  % 10 - 30
compressedLevelRange = 10;  % 1 - 10
lastGain = 0;
lastPower = -100;

if (enableLookAhead)
    musicBuffer = zeros(frameLength + lookAheadSamples, 2);
    sidechainBuffer = zeros(frameLength + lookAheadSamples, 2);
end

if (debug)
    gains = zeros(48000*30,1);
    powers = zeros(48000*30,1);
    gainFrame = zeros(frameLength,1);
    powerFrame = zeros(frameLength,1);
    i = int32(1);

    scope = dsp.TimeScope( ...
        'SampleRate',musicFileR.SampleRate, ...
        'TimeSpan',1, ...
        'BufferLength',48000*4, ...
        'YLimits',[-1,1], ...
        'TimeSpanOverrunAction','Scroll', ...
        'ShowGrid',true, ...
        'LayoutDimensions',[4,1], ...
        'NumInputPorts',4, ...
        'Title', ...
        ['Original vs. Compressed Audio (top)' ...
        ' and Compressor Gain in dB (bottom)']);
    scope.ActiveDisplay = 2;
    scope.YLimits = [-1,1];
    scope.YLabel = 'Amplitude';
    scope.ActiveDisplay = 3;
    scope.YLimits = [-30,0];
    scope.YLabel = 'Gain (dB)';
    scope.ActiveDisplay = 4;
    scope.YLimits = [-100,0];
    scope.YLabel = 'sidechain Power (dB)';
end

while ~isDone(musicFileR)
    
    % read target data and double the power to make more noticable test
    % result
    music = musicFileR()*2;
    [musicRow, musicCol] = size(music);
    if(musicCol == 2) 
        musicMono = (abs(music(:,1)) + abs(music(:,2))) / 2;
        musicout = zeros(frameLength,2);
    else
        musicMono = music;
        musicout = zeros(frameLength,1);
    end
    
    % look ahead on target sound
    if (enableLookAhead)
        buffer = musicBuffer((frameLength+1):(frameLength+lookAheadSamples), :);
        musicBuffer(1:lookAheadSamples, :) = buffer;
        musicBuffer((lookAheadSamples+1):(frameLength+lookAheadSamples), :) = music;
    end
        
    if (~isDone(sidechainFileR))
        
        %% Do sidechain sound analysis
        % read sidechain data
        sidechain = sidechainFileR();
        [row, col] = size(sidechain);
        if(col == 2) 
            sidechainMono = (abs(sidechain(:,1)) + abs(sidechain(:,2))) / 2;
        else
            sidechainMono = sidechain;
        end
        
        % look ahead on sidechain sound
        if (enableLookAhead)
            buffer = sidechainBuffer((frameLength+1):(frameLength+lookAheadSamples), :);
            sidechainBuffer(1:lookAheadSamples, :) = buffer;
            sidechainBuffer((lookAheadSamples+1):(frameLength+lookAheadSamples), :) = sidechain;
        end
        
        % calculate and smooth sidechain power
        sidechainPower = 10.0 * log10(sum(sidechainMono.^2)/length(sidechainMono));
        if (sidechainPower > lastPower)
            sidechainPower = powerAlphaAttack * lastPower + (1-powerAlphaAttack) *sidechainPower;
        else
            sidechainPower = powerAlphaRelease * lastPower + (1-powerAlphaRelease) *sidechainPower;
        end
        lastPower = sidechainPower;

        if (debug)
            if(col == 2) 
                delayedSidechainMono = sidechainBuffer(1:frameLength, 1) + sidechainBuffer(1:frameLength, 2);
            else
                delayedSidechainMono = sidechainBuffer(1:frameLength, 1);
            end
            delayedSidechainPower = 10.0 * log10(sum(delayedSidechainMono.^2)/length(delayedSidechainMono));
        end
        
        % decide threshold and ratio for DRC
        if (sidechainPower > sidechainPowerThreshold)
            T = sidechainPower - thresholdOffset;
            R = -T / compressedLevelRange;
        else
            T = 0;
            R = 1;
        end
        
        %% do DRC
        % calculate target sound power
        sigPower = 10.0 * log10(sum(musicMono.^2)/length(musicMono));
        if (sigPower < (T - kneeWidth/2))
            compressedPower = sigPower;
        elseif (sigPower > (T + kneeWidth/2))
            compressedPower = T + (sigPower - T) / R;
        else
            compressedPower = sigPower + ((1/R - 1) * (sigPower - T + kneeWidth/2)^2 / (2 * kneeWidth));
        end
        compressGain = compressedPower - sigPower;
                
        if (noCompression)
            compressGain = 0;
        end

        % decide smooth coef
        if (compressGain < lastGain)
            alpha = gainAlphaAttack;
        else
            alpha = gainAlphaRelease;
        end
        
        for sample = 1:frameLength
            % calculate smoothed linear gain
            smoothedGain = alpha * lastGain + (1 - alpha) * compressGain;
            lastGain = smoothedGain;
            linearGain = 10.0 .^ (smoothedGain / 20.0);
            
            % apply gain
            if (enableLookAhead)
                musicout(sample,1) = musicBuffer(sample,1) * linearGain;
                if (musicCol == 2)
                    musicout(sample,2) = musicBuffer(sample,2) * linearGain;
                end
            else
                musicout(sample,1) = music(sample,1) * linearGain;
                if (musicCol == 2)
                    musicout(sample,2) = music(sample,2) * linearGain;
                end
            end
            
            if (debug)
                gains(i) = smoothedGain;
                gainFrame(sample) = smoothedGain;
                if (enableLookAhead)
                    powers(i) = delayedSidechainPower;
                    powerFrame(sample) = delayedSidechainPower;
                else
                    powers(i) = sidechainPower;
                    powerFrame(sample) = sidechainPower;
                end
                i = i + 1;
            end
        end

        if (debug)
            if (enableLookAhead)
                scope([musicBuffer(1:frameLength, 1),musicout(:,1)],sidechainBuffer(1:frameLength, 1),gainFrame(:,1), powerFrame(:,1));
            else
                scope([music(:,1),musicout(:,1)],sidechain(:,1),gainFrame(:,1), powerFrame(:,1));
            end
        end
        
    else
        if (enableLookAhead)
            buffer = musicBuffer((frameLength+1):(frameLength+lookAheadSamples), :);
            musicBuffer(1:lookAheadSamples, :) = buffer;
            musicBuffer((lookAheadSamples+1):(frameLength+lookAheadSamples), :) = music;
            musicout = musicBuffer(1:frameLength, :);
            if (debug)
                scope([musicBuffer(1:frameLength, 1),musicout(:,1)],sidechainBuffer(1:frameLength, 1),gainFrame(:,1), powerFrame(:,1));
            end
        else
            musicout = music;
            if (debug)
                scope([music(:,1),musicout(:,1)],sidechain(:,1),gainFrame(:,1), powerFrame(:,1));
            end
        end
    end
    
    if (enableLookAhead)
        musicFileW(musicout + sidechainBuffer(1:frameLength, :));
        if (debug)
            deviceWriter(musicout + sidechainBuffer(1:frameLength, :));
        end
    else
        musicFileW(musicout + sidechain);
        if (debug)
            deviceWriter(musicout + sidechain);
        end
    end
        
end

if (debug)
    plot(gains);
    hold on;
    plot(powers);
end

release(musicFileR);
release(sidechainFileR);
release(musicFileW);
if (debug)
    release(deviceWriter);
    release(scope);
end

end
