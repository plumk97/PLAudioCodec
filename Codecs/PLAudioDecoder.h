//
//  PLAudioDecoder.h
//  PLAudioCodec
//
//  Created by Plumk on 2017/4/20.
//  Copyright © 2017年 Plumk. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudioKit/CoreAudioKit.h>

@protocol PLAudioDecoderDelegate;
@interface PLAudioDecoder : NSObject

@property (nonatomic, weak) id <PLAudioDecoderDelegate> delegate;

@property (nonatomic, assign, readonly) AudioStreamBasicDescription outASBD;
- (instancetype)initWithOutASBD:(AudioStreamBasicDescription)outASBD;

@property (nonatomic, assign, readonly) BOOL isRunning;
- (void)startDecoderWithAudioData:(NSData *)audioData;
- (void)deocdeAudioData:(NSData *)audioData;

- (void)stop;
@end

@protocol PLAudioDecoderDelegate <NSObject>
@optional

- (void)audioDecoder:(PLAudioDecoder *)audioDecoder decodeOnePacketData:(NSData *)packetData;
@end
