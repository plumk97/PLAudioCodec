//
//  PLAudioDecoder.mm
//  PLAudioCodec
//
//  Created by Plumk on 2017/4/20.
//  Copyright © 2017年 Plumk. All rights reserved.
//

#import "PLAudioDecoder.h"
extern "C" {
#import "avformat.h"
#import "avcodec.h"
#import "swresample.h"
#import "libavutil/opt.h"
#import <pthread.h>
}

#define AUDIO_INBUF_SIZE 1024
@interface PLAudioDecoder () {
    
    AVFormatContext * _formatContenxt;
    AVInputFormat * _inputFormat;
    
    AVCodecContext * _codecContext;
    AVCodec * _codec;
    
    
    SwrContext *_swr_context;
    uint8_t ** _swr_src_data;
    int _swr_src_linesize;
    int64_t _swr_src_ch_layout;
    int _swr_src_nb_channels;
    int _swr_src_nb_samples;
    int _swr_src_sample_rate;
    enum AVSampleFormat _swr_src_sample_fmt;
    
    uint8_t ** _swr_dst_data;
    int _swr_dst_nb_channels;
    int _swr_dst_sample_rate;
    int _swr_dst_nb_samples;
    int _swr_max_dst_nb_samples;
    int64_t _swr_dst_ch_layout;
    int _swr_dst_linesize;
    enum AVSampleFormat _swr_dst_sample_fmt;
    
    // raw data
    CFMutableDataRef _wait_swr_data;
    CFMutableDataRef _wait_decode_data;
    
    // thread lock
    pthread_cond_t _wait_encode_cond;
    pthread_mutex_t _wait_encode_mutex;
}
@property (nonatomic, assign) long long offset;
@end


@implementation PLAudioDecoder
@synthesize isRunning = _isRunning;
@synthesize outASBD = _outASBD;


UInt8 _buffer_bit(const UInt8 *buffer, UInt32 n) {
    UInt32 index = n / 8;
    UInt8 buf = buffer[index];
    return buf >> (7 - n % 8) & 0x01;
}

UInt32 _buffer_bit(const void *buffer, UInt32 local, UInt32 length) {
    UInt32 num = 0;
    for (int i = local; i < local + length; i ++) {
        num |= _buffer_bit((const UInt8 *)buffer, i);
        num <<= 1;
    }
    num >>= 1;
    return num;
}

- (instancetype)initWithOutASBD:(AudioStreamBasicDescription)outASBD {
    self = [super init];
    if (self) {
        
        self.offset = 0;
        _wait_swr_data = CFDataCreateMutable(kCFAllocatorDefault, 0);
        _wait_decode_data = CFDataCreateMutable(kCFAllocatorDefault, 0);
        
        pthread_cond_init(&_wait_encode_cond, NULL);
        pthread_mutex_init(&_wait_encode_mutex, NULL);
        
        _outASBD = outASBD;
    }
    return self;
}
- (void)dealloc {
    pthread_cond_destroy(&_wait_encode_cond);
    pthread_mutex_destroy(&_wait_encode_mutex);
    
    CFRelease(_wait_swr_data);
    _wait_swr_data = NULL;
    CFRelease(_wait_decode_data);
    _wait_decode_data = NULL;
    
    [self clearMemory];
}

- (void)clearMemory {
    
    if (_wait_swr_data) {
        CFDataReplaceBytes(_wait_decode_data, CFRangeMake(0, CFDataGetLength(_wait_decode_data)), NULL, 0);
    }
    
    if (_wait_decode_data) {
        CFDataReplaceBytes(_wait_swr_data, CFRangeMake(0, CFDataGetLength(_wait_swr_data)), NULL, 0);
    }
    
    if (_codecContext != NULL) {
        avcodec_close(_codecContext);
        avcodec_free_context(&_codecContext);
        _codecContext = NULL;
    }
    
    if (_swr_context != NULL) {
        swr_free(&_swr_context);
        _swr_context = NULL;
    }
    
    if (_formatContenxt != NULL) {
        av_free(_formatContenxt->pb);
        
        avformat_close_input(&_formatContenxt);
        avformat_free_context(_formatContenxt);
        _formatContenxt = NULL;
    }
}

int read_packet(void *opaque, uint8_t *buf, int buf_size) {
    
    PLAudioDecoder * decoder = (__bridge PLAudioDecoder *)opaque;
    
    CFIndex data_length = CFDataGetLength(decoder->_wait_decode_data);
    if (decoder.offset >= data_length) {
        return -1;
    }
    
    long long length = MIN(buf_size, (data_length - decoder.offset));
    
    UInt8 * getBytes = (UInt8 *)malloc(length);
    CFDataGetBytes(decoder->_wait_decode_data, CFRangeMake(decoder.offset, length), getBytes);
    
    memmove(buf, getBytes, length);
    decoder.offset += length;
    
    free(getBytes);
    return buf_size;
}

int64_t seek(void *opaque, int64_t offset, int whence) {
    
    if (whence == AVSEEK_SIZE) {
        return -1;
    }
    PLAudioDecoder * decoder = (__bridge PLAudioDecoder *)opaque;
    decoder.offset = whence + offset;
    return decoder.offset;
}


- (void)startDecoderWithAudioData:(NSData *)audioData {
    
    if (self.isRunning) return;
    
    CFDataAppendBytes(_wait_decode_data, (const UInt8 *)[audioData bytes], audioData.length);
    if (CFDataGetLength(_wait_decode_data) < AUDIO_INBUF_SIZE) return;
    
    av_register_all();
    avcodec_register_all();
    
    _formatContenxt = avformat_alloc_context();
    
    unsigned char * buffer = (unsigned char *)av_malloc(AUDIO_INBUF_SIZE);
    AVIOContext * ioContext = avio_alloc_context(buffer, AUDIO_INBUF_SIZE, 0, (__bridge void *)self, &read_packet, NULL, &seek);
    if (!ioContext) {
        NSLog(@"Failed Alloc AVIOContext");
        return;
    }
    
    if (av_probe_input_buffer(ioContext, &_inputFormat, "", NULL, 0, 0) < 0) {
        NSLog(@"Failed probe failed");
        return;
    }
    
    _formatContenxt->pb = ioContext;
    _formatContenxt->flags = AVFMT_FLAG_CUSTOM_IO;
    
    if (avformat_open_input(&_formatContenxt, "", _inputFormat, NULL) < 0) {
        NSLog(@"AVFormat open failed");
        return;
    }
    
    if (avformat_find_stream_info(_formatContenxt, NULL) < 0) {
        NSLog(@"AVFormat not find stream");
        return;
    }
    
    int audioStream = -1;
    for (int i = 0; i < _formatContenxt->nb_streams; i ++) {
        if (_formatContenxt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audioStream = i;
            break;
        }
    }
    
    if (audioStream < 0) {
        NSLog(@"Can not find codec stream");
        return;
    }
    
    AVCodecParameters * codecpar = _formatContenxt->streams[audioStream]->codecpar;
    
    if (codecpar->codec_id == AV_CODEC_ID_AAC) {
        _codec = avcodec_find_decoder_by_name("libfdk_aac");
    }
    
    if (!_codec) {
        _codec = avcodec_find_decoder(codecpar->codec_id);
    }
    
    NSLog(@"%s", avcodec_get_name(_codec->id));
    if (_codec == NULL) {
        NSLog(@"Can not find decoder");
        return;
    }
    _codecContext = avcodec_alloc_context3(_codec);
    _codecContext->sample_fmt = self.outASBD.mChannelsPerFrame == 1 ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S16;
    avcodec_parameters_to_context(_codecContext, codecpar);
    
    if (avcodec_open2(_codecContext, _codec, NULL) < 0) {
        NSLog(@"Can not open codec");
        return;
    }
    
    NSLog(@"channels:%d", _codecContext->channels);
    NSLog(@"sample_fmt:%s", av_get_sample_fmt_name(_codecContext->sample_fmt));
    NSLog(@"sample_rate:%d", _codecContext->sample_rate);
    
    if ([self isNeedResample]) {
        /* create resampler context */
        _swr_context = swr_alloc();
        if (!_swr_context) {
            NSLog(@"Could not allocate resampler context");
            return;
        }
        /* set options */
        
        // in
        _swr_src_nb_samples = 1024;
        _swr_src_sample_fmt = _codecContext->sample_fmt;
        _swr_src_sample_rate = _codecContext->sample_rate;
        _swr_src_ch_layout = _codecContext->channel_layout;
        _swr_src_nb_channels = av_get_channel_layout_nb_channels(_swr_src_ch_layout);
        
        av_opt_set_int(_swr_context, "in_channel_layout",       _swr_src_ch_layout, 0);
        av_opt_set_int(_swr_context, "in_sample_rate",          _swr_src_sample_rate, 0);
        av_opt_set_sample_fmt(_swr_context, "in_sample_fmt",    _swr_src_sample_fmt, 0);
        
        // out
        _swr_dst_sample_fmt = self.outASBD.mChannelsPerFrame == 1 ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S16P;
        _swr_dst_sample_rate = self.outASBD.mSampleRate;
        _swr_dst_ch_layout = self.outASBD.mChannelsPerFrame == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;
        _swr_dst_nb_channels = av_get_channel_layout_nb_channels(_swr_dst_ch_layout);
        
        av_opt_set_int(_swr_context, "out_channel_layout",      _swr_dst_ch_layout, 0);
        av_opt_set_int(_swr_context, "out_sample_rate",         _swr_dst_sample_rate, 0);
        av_opt_set_sample_fmt(_swr_context, "out_sample_fmt",   _swr_dst_sample_fmt, 0);
        
        if (swr_init(_swr_context) < 0) {
            NSLog(@"Failed to initialize the resampling context");
            return;
        }
        
        
        int ret = av_samples_alloc_array_and_samples(&_swr_src_data, &_swr_src_linesize, _swr_src_nb_channels, _swr_src_nb_samples, _swr_src_sample_fmt, 0);
        if (ret < 0) {
            NSLog(@"Could not allocate source samples");
            return;
        }
        
        _swr_max_dst_nb_samples = _swr_dst_nb_samples = (int)av_rescale_rnd(_swr_src_nb_samples, _swr_dst_sample_rate, _swr_src_sample_rate, AV_ROUND_UP);
        
        ret = av_samples_alloc_array_and_samples(&_swr_dst_data, &_swr_dst_linesize, _swr_dst_nb_channels, _swr_dst_nb_samples, _swr_dst_sample_fmt, 0);
        if (ret < 0) {
            NSLog(@"Could not allocate destination samples");
            return;
        }
    }
    
    CFDataReplaceBytes(_wait_decode_data, CFRangeMake(0, CFDataGetLength(_wait_decode_data)), NULL, 0);
    
    _isRunning = YES;
    [NSThread detachNewThreadSelector:@selector(thread_decoder) toTarget:self withObject:nil];
}

- (BOOL)isNeedResample {
    return
    !(_codecContext->channels == self.outASBD.mChannelsPerFrame &&
      av_get_bytes_per_sample(_codecContext->sample_fmt) * 8 == self.outASBD.mBitsPerChannel &&
      _codecContext->sample_rate == self.outASBD.mSampleRate);
}

- (void)deocdeAudioData:(NSData *)audioData {
    
    if (!self.isRunning) return;
    
    CFDataAppendBytes(_wait_decode_data, (const UInt8 *)[audioData bytes], audioData.length);
    [self signal_pthread];
}

- (void)stop {
    
    if (self.isRunning) {
        _isRunning = NO;
        [self signal_pthread];
        [self wait_pthread];
    };
    
    [self clearMemory];
}

- (void)signal_pthread {
    pthread_mutex_lock(&_wait_encode_mutex);
    pthread_cond_signal(&_wait_encode_cond);
    pthread_mutex_unlock(&_wait_encode_mutex);
}

- (void)wait_pthread {
    pthread_mutex_lock(&_wait_encode_mutex);
    pthread_cond_wait(&_wait_encode_cond, &_wait_encode_mutex);
    pthread_mutex_unlock(&_wait_encode_mutex);
}

- (CFRange)getOnePacketDataRange {
    
    CFIndex data_len = CFDataGetLength(_wait_decode_data);
    if (_codec->id == AV_CODEC_ID_AAC) {
        
        const UInt8 * bytes = CFDataGetBytePtr(_wait_decode_data);
        int local = -1;
        for (int i = 0; i < data_len; i ++) {
            if (_buffer_bit(bytes, i, 12) == 0xFFF) {
                local = i;
                break;
            }
        }
        if (local < 0) return CFRangeMake(0, -1);
        
        int frame_len = _buffer_bit(bytes, local + 30, 13);
        return CFRangeMake(local, frame_len);
        
    } else if (_codec->id == AV_CODEC_ID_AMR_NB) {
        
        if (data_len < 32) return CFRangeMake(0, -1);
        return CFRangeMake(0, 32);
    }
    
    if (data_len < AUDIO_INBUF_SIZE) return CFRangeMake(0, -1);
    return CFRangeMake(0, AUDIO_INBUF_SIZE);
}

- (void)thread_decoder {
    
    AVFrame * frame = av_frame_alloc();
    frame->nb_samples = _codecContext->frame_size;
    frame->format = _codecContext->sample_fmt;
    
    int buf_size;
    AVPacket pkt;
    av_init_packet(&pkt);
    
    uint8_t * inBuffer = NULL;
    
    while (self.isRunning) {
        
        CFRange range = [self getOnePacketDataRange];
        if (range.length < 0) {
            [self wait_pthread];
            continue;
        }
        
        if (inBuffer != NULL) {
            av_free(inBuffer);
            inBuffer = NULL;
        }
        
        buf_size = (int)range.length;
        inBuffer = (uint8_t *)av_malloc(buf_size);
        
        UInt8 * bytes = (UInt8 *)malloc(buf_size);
        CFDataGetBytes(_wait_decode_data, range, bytes);
        memcpy(inBuffer, bytes, buf_size);
        
        free(bytes);
        if (range.location + range.length >= CFDataGetLength(_wait_decode_data)) {
            CFDataReplaceBytes(_wait_decode_data, CFRangeMake(0, CFDataGetLength(_wait_decode_data)), NULL, 0);
        } else {
            CFDataReplaceBytes(_wait_decode_data, CFRangeMake(0, range.location + range.length), NULL, 0);
        }
        
        pkt.data = inBuffer;
        pkt.size = buf_size;
        
        int ret = avcodec_send_packet(_codecContext, &pkt);
        if (ret != 0) {
            continue;
        }
        
        while (!ret) {
            ret = avcodec_receive_frame(_codecContext, frame);
            if (ret == 0) {
                
                @autoreleasepool {
                    for (int c = 0; c < _codecContext->channels; c ++) {
                        CFDataAppendBytes(_wait_swr_data, (UInt8 *)(frame->data[c]), frame->linesize[c]);
                    }
                    [self executeResample];
                }
            }
            av_frame_unref(frame);
        }
        av_packet_unref(&pkt);
        
    }
    
    if (inBuffer != NULL) {
        av_free(inBuffer);
    }
    
    av_packet_unref(&pkt);
    av_frame_free(&frame);
    [self signal_pthread];
}

- (void)executeResample {
    
    CFIndex wait_swr_data_length = CFDataGetLength(_wait_swr_data);
    if (![self isNeedResample]) {
        
        CFRange range = CFRangeMake(0, wait_swr_data_length);
        if (self.delegate && [self.delegate respondsToSelector:@selector(audioDecoder:decodeOnePacketData:)]) {
            [self.delegate audioDecoder:self decodeOnePacketData:(__bridge NSData *)_wait_swr_data];
        }
        CFDataReplaceBytes(_wait_swr_data, range, NULL, 0);
        return;
    }
    if (wait_swr_data_length < _swr_src_linesize) return;
    
    CFRange range = CFRangeMake(0, _swr_src_linesize);
    CFDataGetBytes(_wait_swr_data, range, _swr_src_data[0]);
    CFDataReplaceBytes(_wait_swr_data, range, NULL, 0);
    
    for (int i = 1; i < _swr_src_nb_channels; i ++) {
        _swr_src_data[i] = _swr_src_data[0];
    }
    
    _swr_dst_nb_samples = (int)av_rescale_rnd(swr_get_delay(_swr_context, _swr_src_sample_rate) + _swr_src_nb_samples, _swr_dst_sample_rate, _swr_src_sample_rate, AV_ROUND_UP);
    
    int ret = 0;
    if (_swr_dst_nb_samples > _swr_max_dst_nb_samples) {
        av_freep(&_swr_dst_data[0]);
        ret = av_samples_alloc(_swr_dst_data, &_swr_dst_linesize, _swr_dst_nb_channels, _swr_dst_nb_samples, _swr_dst_sample_fmt, 1);
        if (ret < 0)
            return;
        _swr_max_dst_nb_samples = _swr_dst_nb_samples;
    }
    
    ret = swr_convert(_swr_context, _swr_dst_data, _swr_dst_nb_samples, (const uint8_t **)_swr_src_data, _swr_src_nb_samples);
    if (ret < 0) {
        return;
    }
    
    int swr_dst_bufsize = av_samples_get_buffer_size(&_swr_dst_linesize, _swr_dst_nb_channels, ret, _swr_dst_sample_fmt, 1);
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(audioDecoder:decodeOnePacketData:)]) {
        [self.delegate audioDecoder:self decodeOnePacketData:[NSData dataWithBytes:_swr_dst_data[0] length:swr_dst_bufsize]];
    }
}

@end
