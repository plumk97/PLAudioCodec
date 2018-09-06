//
//  PLAudioEncoder.mm
//  PLAudioCodec
//
//  Created by Plumk on 2017/4/19.
//  Copyright © 2017年 Plumk. All rights reserved.
//

#import "PLAudioEncoder.h"

extern "C" {
#import "avformat.h"
#import "avcodec.h"
#import "swresample.h"
#import "libavutil/opt.h"
#import <pthread.h>
}


@interface PLAudioEncoder () {
    
    AVFormatContext * _formatContenxt;
    AVOutputFormat * _outputFormat;
    AVStream * _stream;
    
    AVCodecContext * _codecContext;
    AVCodec * _codec;
    
    // swr
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
    
    
    AVFrame * _frame;
    int _frame_size;
    uint8_t * _frame_buf;
    
    unsigned char * _ioContextbuffer;
    
    // raw data
    CFMutableDataRef _wait_swr_data;
    CFMutableDataRef _wait_swr_encode_data;
    
    // thread lock
    pthread_cond_t _wait_encode_cond;
    pthread_mutex_t _wait_encode_mutex;
    
    pthread_cond_t _wait_stop_cond;
    pthread_mutex_t _wait_stop_mutex;
}
@property (nonatomic, assign) BOOL threadRuning;
@end
@implementation PLAudioEncoder
@synthesize inASBD = _inASBD;
@synthesize outASBD = _outASBD;
@synthesize outFile = _outFile;

void signal_pthread(pthread_mutex_t * mutex, pthread_cond_t * cond) {
    pthread_mutex_lock(mutex);
    pthread_cond_signal(cond);
    pthread_mutex_unlock(mutex);
}

void wait_pthread(pthread_mutex_t * mutex, pthread_cond_t * cond) {
    pthread_mutex_lock(mutex);
    pthread_cond_wait(cond, mutex);
    pthread_mutex_unlock(mutex);
}

int flush_encoder(AVFormatContext *fmt_ctx, AVCodec * codec, AVCodecContext * codecContext){
    
    if (fmt_ctx == NULL || codec == NULL || codecContext == NULL) {
        return 0;
    }
    
    int ret;
    AVPacket enc_pkt;
    if (!(codec->capabilities &
          AV_CODEC_CAP_DELAY))
        return 0;
    while (1) {
        
        ret = avcodec_send_frame(codecContext, NULL);
        
        enc_pkt.data = NULL;
        enc_pkt.size = 0;
        av_init_packet(&enc_pkt);
        
        ret = avcodec_receive_packet(codecContext, &enc_pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            return 0;
        av_frame_free(NULL);
        
        if (ret < 0)
            break;
        
        printf("Flush Encoder: Succeed to encode 1 frame!\tsize:%5d\n",enc_pkt.size);
        /* mux encoded frame */
        ret = av_write_frame(fmt_ctx, &enc_pkt);
        if (ret < 0)
            break;
    }
    return ret;
}



- (instancetype)initWithInASBD:(AudioStreamBasicDescription)inASBD outASBD:(AudioStreamBasicDescription)outASBD {
    return [self initWithInASBD:inASBD outASBD:outASBD outFile:nil];
}

- (instancetype)initWithInASBD:(AudioStreamBasicDescription)inASBD outASBD:(AudioStreamBasicDescription)outASBD outFile:(NSString *)outFile {
    
    self = [super init];
    if (self) {
        
        _inASBD = inASBD;
        _outASBD = outASBD;
        _outFile = outFile;
        if (![self setup]) {
            return nil;
        }
    }
    return self;
}

- (NSString *)audioFormat {
    if (self.outASBD.mFormatID == kAudioFormatLinearPCM) {
        return @".wav";
    } else if (self.outASBD.mFormatID == kAudioFormatAMR) {
        return @".amr";
    } else if (self.outASBD.mFormatID == kAudioFormatMPEG4AAC) {
        return @".aac";
    }
    return nil;
}

- (BOOL)setup {
    
    //    av_register_all();
    //    avcodec_register_all();
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.outFile]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.outFile error:nil];
    }
    
    _wait_swr_data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    _wait_swr_encode_data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    
    const char * outFilename = [[self audioFormat] UTF8String];
    
    _formatContenxt = avformat_alloc_context();
    _outputFormat = av_guess_format(NULL, outFilename, NULL);
    _formatContenxt->oformat = _outputFormat;
    
    if (self.outFile) {
        if (avio_open(&_formatContenxt->pb, [_outFile UTF8String], AVIO_FLAG_READ_WRITE) < 0){
            printf("Failed to open output file!\n");
            return NO;
        }
    } else {
        _ioContextbuffer = (unsigned char *)av_malloc(32768);
        AVIOContext * ioContext = avio_alloc_context(_ioContextbuffer, 32768, 1, (__bridge void *)self, NULL, NULL, NULL);
        _formatContenxt->pb = ioContext;
    }
    
    _stream = avformat_new_stream(_formatContenxt, 0);
    if (_stream == nil) {
        NSLog(@"failed to create stream");
        return NO;
    }
    
    
    AVCodecParameters * codecpar = _stream->codecpar;
    
    codecpar->codec_id = _outputFormat->audio_codec;
    codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    
    codecpar->sample_rate = self.outASBD.mSampleRate;
    codecpar->channel_layout = self.outASBD.mChannelsPerFrame == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;
    codecpar->channels = av_get_channel_layout_nb_channels(codecpar->channel_layout);
    if (self.outASBD.mFormatID == kAudioFormatMPEG4AAC) {
        codecpar->bit_rate = 64 * 1000; // 64k
    } else if (self.outASBD.mFormatID == kAudioFormatAMR) {
        codecpar->bit_rate = 12.2 * 1000; // 12.2k
    }
    
    // out format
    av_dump_format(_formatContenxt, 0, outFilename, 1);
    
    if (codecpar->codec_id != AV_CODEC_ID_FIRST_AUDIO) {
        /** not pcm format */
        if (codecpar->codec_id == AV_CODEC_ID_AAC) {
            _codec = avcodec_find_encoder_by_name("libfdk_aac");
        }
        
        if (!_codec) {
            _codec = avcodec_find_encoder(codecpar->codec_id);
        }
        
        if (!_codec) {
            NSLog(@"Can not find encoder");
            return NO;
        }
        
        _codecContext = avcodec_alloc_context3(_codec);
        avcodec_parameters_to_context(_codecContext, codecpar);
        _codecContext->sample_fmt = [self formatWithASBD:self.outASBD];
        
        if (avcodec_open2(_codecContext, _codec, NULL)) {
            NSLog(@"Failed to open encoder");
            return NO;
        }
        
        /** create frame */
        _frame = av_frame_alloc();
        _frame->nb_samples = _codecContext->frame_size;
        _frame->format = _codecContext->sample_fmt;
        _frame->channel_layout = _codecContext->channel_layout;
        
        _frame_size = av_samples_get_buffer_size(NULL, _codecContext->channels, _codecContext->frame_size, _codecContext->sample_fmt, 1);
        
        _frame_buf = (uint8_t *)av_malloc(_frame_size);
        avcodec_fill_audio_frame(_frame, _codecContext->channels, _codecContext->sample_fmt, (const uint8_t *)_frame_buf, _frame_size, 1);
    }
    
    
    if (avformat_write_header(_formatContenxt, NULL) < 0) {
        NSLog(@"write header failed");
    }
    
    /* create resampler context */
    if ([self isNeedResample]) {
        _swr_context = swr_alloc();
        if (!_swr_context) {
            NSLog(@"Could not allocate resampler context");
            return NO;
        }
        /* set options */
        
        // in
        _swr_src_nb_samples = 1024;
        _swr_src_sample_fmt = [self formatWithASBD:self.inASBD];
        _swr_src_sample_rate = self.inASBD.mSampleRate;
        _swr_src_ch_layout = self.inASBD.mChannelsPerFrame == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;
        _swr_src_nb_channels = av_get_channel_layout_nb_channels(_swr_src_ch_layout);
        
        av_opt_set_int(_swr_context, "in_channel_layout",       _swr_src_ch_layout, 0);
        av_opt_set_int(_swr_context, "in_sample_rate",          _swr_src_sample_rate, 0);
        av_opt_set_sample_fmt(_swr_context, "in_sample_fmt",    _swr_src_sample_fmt, 0);
        
        
        // out
        _swr_dst_sample_fmt = [self formatWithASBD:self.outASBD];
        _swr_dst_sample_rate = self.outASBD.mSampleRate;
        _swr_dst_ch_layout = self.outASBD.mChannelsPerFrame == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;
        _swr_dst_nb_channels = av_get_channel_layout_nb_channels(_swr_dst_ch_layout);
        
        av_opt_set_int(_swr_context, "out_channel_layout",      _swr_dst_ch_layout, 0);
        av_opt_set_int(_swr_context, "out_sample_rate",         _swr_dst_sample_rate, 0);
        av_opt_set_sample_fmt(_swr_context, "out_sample_fmt",   _swr_dst_sample_fmt, 0);
        
        if (swr_init(_swr_context) < 0) {
            NSLog(@"Failed to initialize the resampling context");
            return NO;
        }
        
        
        int ret = av_samples_alloc_array_and_samples(&_swr_src_data, &_swr_src_linesize, _swr_src_nb_channels, _swr_src_nb_samples, _swr_src_sample_fmt, 0);
        if (ret < 0) {
            NSLog(@"Could not allocate source samples");
            return NO;
        }
        
        _swr_max_dst_nb_samples = _swr_dst_nb_samples = (int)av_rescale_rnd(_swr_src_nb_samples, _swr_dst_sample_rate, _swr_src_sample_rate, AV_ROUND_UP);
        
        ret = av_samples_alloc_array_and_samples(&_swr_dst_data, &_swr_dst_linesize, _swr_dst_nb_channels, _swr_dst_nb_samples, _swr_dst_sample_fmt, 0);
        if (ret < 0) {
            NSLog(@"Could not allocate destination samples");
            return NO;
        }
    }
    
    /* thread create */
    self.threadRuning = YES;
    pthread_cond_init(&_wait_encode_cond, NULL);
    pthread_mutex_init(&_wait_encode_mutex, NULL);
    
    pthread_cond_init(&_wait_stop_cond, NULL);
    pthread_mutex_init(&_wait_stop_mutex, NULL);
    
    [NSThread detachNewThreadSelector:@selector(thread_encoder) toTarget:self withObject:nil];
    return YES;
}

- (AVSampleFormat)formatWithASBD:(AudioStreamBasicDescription)asbd {
    if (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) {
            return AV_SAMPLE_FMT_FLTP;
        } else {
            return AV_SAMPLE_FMT_S16P;
        }
    } else if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) {
        return AV_SAMPLE_FMT_FLT;
    }
    return AV_SAMPLE_FMT_S16;
}

- (BOOL)isNeedResample {
    
    AVSampleFormat
    inFormat = [self formatWithASBD:self.inASBD],
    outFormat = [self formatWithASBD:self.outASBD];
    
    return
    !(self.inASBD.mChannelsPerFrame == self.outASBD.mChannelsPerFrame &&
      self.inASBD.mBitsPerChannel == self.outASBD.mBitsPerChannel &&
      self.inASBD.mSampleRate == self.outASBD.mSampleRate &&
      inFormat == outFormat);
}

- (void)dealloc {
    [self releaseSource];
}

- (void)releaseSource {
    
    if (_formatContenxt != NULL) {
        flush_encoder(_formatContenxt, _codec, _codecContext);
        
        if (_codec != NULL && _codecContext != NULL) {
            av_write_trailer(_formatContenxt);
        }
        
        if (_swr_context) {
            av_freep(&_swr_dst_data[0]);
            av_freep(&_swr_dst_data);
            
            av_freep(&_swr_src_data[0]);
            av_freep(&_swr_src_data);
            
            swr_free(&_swr_context);
        }
        
        if (_stream){
            avcodec_close(_codecContext);
            avcodec_free_context(&_codecContext);
            
            av_free(_frame);
            av_free(_frame_buf);
        }
        
        if (!self.outFile) {
            av_free(_formatContenxt->pb);
            av_free(_ioContextbuffer);
        } else {
            avio_close(_formatContenxt->pb);
        }
    
        avformat_free_context(_formatContenxt);
        _formatContenxt = NULL;
    }
    
    if (_wait_swr_data != NULL) {
        CFRelease(_wait_swr_data);
        CFRelease(_wait_swr_encode_data);
        _wait_swr_data = NULL;
        _wait_swr_encode_data = NULL;
    }
    
    pthread_mutex_destroy(&_wait_encode_mutex);
    pthread_cond_destroy(&_wait_encode_cond);
    
    pthread_mutex_destroy(&_wait_stop_mutex);
    pthread_cond_destroy(&_wait_stop_cond);
}

- (void)stop {
    if (self.threadRuning) {
        self.threadRuning = NO;
        signal_pthread(&_wait_encode_mutex, &_wait_encode_cond);
        wait_pthread(&_wait_stop_mutex, &_wait_stop_cond);
    }
    [self releaseSource];
}

- (void)encoderPCMBytes:(const void *)bytes length:(UInt32)size {
    CFDataAppendBytes(_wait_swr_data, (const UInt8 *)bytes, size);
    if (self.threadRuning) {
        signal_pthread(&_wait_encode_mutex, &_wait_encode_cond);
    }
}

- (void)encoderPCMData:(NSData *)pcmData {
    [self encoderPCMBytes:[pcmData bytes] length:(UInt32)[pcmData length]];
}

- (void)thread_encoder {
    while (self.threadRuning) {
        
        int wait_swr_data_length = (int)CFDataGetLength(_wait_swr_data);
        if (wait_swr_data_length <= 0 || wait_swr_data_length < _swr_src_linesize) {
            wait_pthread(&_wait_encode_mutex, &_wait_encode_cond);
            continue;
        }
        
        if (![self isNeedResample]) {
            
            UInt8 * buffer = (UInt8 *)malloc(wait_swr_data_length);
            
            CFRange range = CFRangeMake(0, wait_swr_data_length);
            CFDataGetBytes(_wait_swr_data, range, buffer);
            CFDataReplaceBytes(_wait_swr_data, range, NULL, 0);
            
            [self executeEncodeData:buffer size:wait_swr_data_length];
            free(buffer);
            continue;
        }
        
        
        /** resample */
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
                continue;
            _swr_max_dst_nb_samples = _swr_dst_nb_samples;
        }
        
        ret = swr_convert(_swr_context, _swr_dst_data, _swr_dst_nb_samples, (const uint8_t **)_swr_src_data, _swr_src_nb_samples);
        if (ret < 0) {
            continue;
        }
        
        int swr_dst_bufsize = av_samples_get_buffer_size(&_swr_dst_linesize, _swr_dst_nb_channels, ret, _swr_dst_sample_fmt, 1);
        [self executeEncodeData:_swr_dst_data[0] size:swr_dst_bufsize];
    }
    signal_pthread(&_wait_stop_mutex, &_wait_stop_cond);
}

- (void)executeEncodeData:(const UInt8 *)data size:(int)size {
    @autoreleasepool {
        if ([self.delegate respondsToSelector:@selector(audioEncoder:resampleOnePacketData:size:)]) {
            [self.delegate audioEncoder:self resampleOnePacketData:data size:size];
        }
        
        if (self.outASBD.mFormatID == kAudioFormatLinearPCM) {
            
            AVPacket packet;
            av_new_packet(&packet, size);
            
            packet.data = (uint8_t *)data;
            packet.size = size;
            packet.stream_index = _stream->index;
            av_write_frame(_formatContenxt, &packet);
            
            if (self.delegate && [self.delegate respondsToSelector:@selector(audioEncoder:encodeOnePacketData:)]) {
                [self.delegate audioEncoder:self encodeOnePacketData:[NSData dataWithBytes:(const void *)packet.data length:packet.size]];
            }
            
            av_packet_unref(&packet);
            return;
        }
        
        /** encode */
        CFDataAppendBytes(_wait_swr_encode_data, (const UInt8 *)data, size);
        while (1) {
            
            if (CFDataGetLength(_wait_swr_encode_data) < _frame_size) {
                break;
            }
            CFRange range = CFRangeMake(0, _frame_size);
            CFDataGetBytes(_wait_swr_encode_data, range, _frame_buf);
            CFDataReplaceBytes(_wait_swr_encode_data, range, NULL, 0);
            
            _frame->data[0] = _frame_buf;
            int ret = avcodec_send_frame(_codecContext, _frame);
            if (ret != 0) {
                break;
            }
            
            AVPacket packet;
            av_new_packet(&packet, _frame_size);
            
            while (!ret) {
                ret = avcodec_receive_packet(_codecContext, &packet);
                if (ret == 0) {
                    packet.stream_index = _stream->index;
                    av_write_frame(_formatContenxt, &packet);
                    if (self.delegate && [self.delegate respondsToSelector:@selector(audioEncoder:encodeOnePacketData:)]) {
                        [self.delegate audioEncoder:self encodeOnePacketData:[NSData dataWithBytes:(const void *)packet.data length:packet.size]];
                    }
                    
                }
                av_packet_unref(&packet);
            }
            av_free(packet.data);
        }
    }
}

@end
