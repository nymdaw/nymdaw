module dseq;

import std.stdio;

import jack.client;
import sndfile.sndfile;

class AudioError: Exception {
    this(string msg) {
        super(msg);
    }
}

void mixer() {
    string clientName = "dseq";

    JackClient client = new JackClient;
    try {
        client.open(clientName, JackOptions.JackNoStartServer, null);
    }
    catch(JackError e) {
        throw new AudioError(e.msg);
    }

    scope(exit) client.close();

    JackPort mixOut1 = client.register_port("Mix1", JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);
    JackPort mixOut2 = client.register_port("Mix2", JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);

    client.process_callback = delegate int(jack_nframes_t nframes) {
        float* mixBuf1 = mixOut1.get_audio_buffer(nframes);
        float* mixBuf2 = mixOut2.get_audio_buffer(nframes);

        return 0;
    };

    client.activate();

    stdin.readln();
}

void main()
{
    try {
        mixer();
    }
    catch(AudioError e) {
        writeln("Fatal audio error: ", e.msg);
    }
}
