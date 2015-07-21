#include <CoreAudio/CoreAudio.h>
#include <AudioUnit/AudioUnit.h>

typedef unsigned int nframes_t;
typedef float sample_t;
typedef unsigned int channels_t;

static const int FORMAT_FLAGS = kAudioFormatFlagIsFloat;

static AudioComponent outputComponent;
static AudioComponentInstance outputInstance;

static char* errorString = NULL;

char* coreAudioErrorString() {
    return errorString;
}

bool coreAudioInit() {
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    outputComponent = AudioComponentFindNext(NULL, &desc);
    if(!outputComponent || AudioComponentInstanceNew(outputComponent, &outputInstance)) {
        errorString = "Failed to open default audio device";
        return false;
    }

    return true;
}

void coreAudioCleanup() {
    AudioOutputUnitStop(outputInstance);
    AudioComponentInstanceDispose(outputInstance);
}

bool coreAudioOpen(nframes_t sampleRate, channels_t nChannels, AURenderCallback* callback) {
    if(AudioUnitInitialize(outputInstance)) {
        errorString = "Unable to initialize audio unit instance";
        return false;
    }

    AudioStreamBasicDescription streamFormat;
    streamFormat.mSampleRate = sampleRate;
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags = FORMAT_FLAGS;
    streamFormat.mBytesPerPacket = nChannels * sizeof(sample_t);
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mBytesPerFrame = nChannels * sizeof(sample_t);
    streamFormat.mChannelsPerFrame = nChannels;
    streamFormat.mBitsPerChannel = 8 * sizeof(sample_t);

    if(AudioUnitSetProperty(outputInstance,
                            kAudioUnitProperty_StreamFormat,
                            kAudioUnitScope_Input,
                            0,
                            &streamFormat,
                            sizeof(streamFormat))) {
        errorString = "Failed to set audio unit input property";
        return false;
    }

    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = *callback;
    callbackStruct.inputProcRefCon = NULL;

    if(AudioUnitSetProperty(outputInstance,
                            kAudioUnitProperty_SetRenderCallback,
                            kAudioUnitScope_Input,
                            0,
                            &callback,
                            sizeof(AURenderCallbackStruct))) {
        errorString = "Unable to attach an IOProc to the selected audio unit";
        return false;
    }

    if(AudioOutputUnitStart(outputInstance)) {
        errorString = "Unable to start audio unit";
        return false;
    }

    return true;
}
