#include <CoreAudio/CoreAudio.h>
#include <AudioUnit/AudioUnit.h>

typedef unsigned int nframes_t;
typedef float sample_t;
typedef unsigned int channels_t;

static const int FORMAT_FLAGS = kAudioFormatFlagIsFloat;

static AudioComponent outputComponent;
static AudioComponentInstance outputInstance;

static char* errorString = NULL;

typedef void (*AudioCallback)(nframes_t, channels_t, sample_t*);
static AudioCallback currentAudioCallback = NULL;

static OSStatus coreAudioCallback(void* inRefCon,
                                  AudioUnitRenderActionFlags* ioActionFlags,
                                  const AudioTimeStamp* inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList* ioData) {
    (*currentAudioCallback)(ioData->mBuffers[0].mDataByteSize / sizeof(sample_t),
                            ioData->mBuffers[0].mNumberChannels,
                            (sample_t*)ioData->mBuffers[0].mData);
    return 0;
}

char* coreAudioErrorString() {
    return errorString;
}

bool coreAudioInit(nframes_t sampleRate, channels_t nChannels, AudioCallback audioCallback) {
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    desc.componentManufacturer = 0;

    outputComponent = AudioComponentFindNext(NULL, &desc);
    if(!outputComponent || AudioComponentInstanceNew(outputComponent, &outputInstance)) {
        errorString = "Failed to open default audio device";
        return false;
    }

    if(AudioUnitInitialize(outputInstance)) {
        errorString = "Unable to initialize audio unit instance";
        return false;
    }

    currentAudioCallback = audioCallback;

    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = &coreAudioCallback;
    callbackStruct.inputProcRefCon = NULL;

    if(AudioUnitSetProperty(outputInstance,
                            kAudioUnitProperty_SetRenderCallback,
                            kAudioUnitScope_Input,
                            0,
                            &callbackStruct,
                            sizeof(AURenderCallbackStruct))) {
        errorString = "Unable to attach an IOProc to the selected audio unit";
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

    if(AudioOutputUnitStart(outputInstance)) {
        errorString = "Unable to start audio unit";
        return false;
    }

    return true;
}

void coreAudioCleanup() {
    AudioOutputUnitStop(outputInstance);
    AudioComponentInstanceDispose(outputInstance);
}
