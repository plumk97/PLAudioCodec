//
//  PLAudioEncoder.h
//  PLAudioCodec
//
//  Created by Plumk on 2017/4/19.
//  Copyright © 2017年 Plumk. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudioKit/CoreAudioKit.h>

@protocol PLAudioEncoderDelegate;
@interface PLAudioEncoder : NSObject

@property (nonatomic, assign, readonly) AudioStreamBasicDescription inASBD;
@property (nonatomic, assign, readonly) AudioStreamBasicDescription outASBD;
@property (nonatomic, copy, readonly) NSString * outFile;

@property (nonatomic, weak) id <PLAudioEncoderDelegate> delegate;

- (instancetype)initWithInASBD:(AudioStreamBasicDescription)inASBD outASBD:(AudioStreamBasicDescription)outASBD;
- (instancetype)initWithInASBD:(AudioStreamBasicDescription)inASBD outASBD:(AudioStreamBasicDescription)outASBD outFile:(NSString *)outFile;

- (void)encoderPCMBytes:(const void *)bytes length:(UInt32)size;
- (void)encoderPCMData:(NSData *)pcmData;

- (void)stop;
@end

@protocol PLAudioEncoderDelegate <NSObject>
@optional


/**
 重采样一段数据

 @param audioEncoder
 @param packetData
 @param size
 */
- (void)audioEncoder:(PLAudioEncoder *)audioEncoder resampleOnePacketData:(const UInt8 *)packetData size:(UInt32)size;

/**
 编码完成一段数据

 @param audioEncoder
 @param packetData 
 */
- (void)audioEncoder:(PLAudioEncoder *)audioEncoder encodeOnePacketData:(NSData *)packetData;
@end
