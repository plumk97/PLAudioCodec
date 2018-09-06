## FFmpeg-iOS 编译脚本

这个脚本是我在 [kewlbear](https://github.com/kewlbear/FFmpeg-iOS-build-script) 的 FFmpeg-iOS-build-script 基础上修改，只激活了AAC、AMR、PCM音频编码器减少包的大小

编译之前先解压 `codec.tar.bz2`文件，里面包含了 **fdk-aac-ios** 和 **opencore-amr-ios** 静态库

编译完成之后需要把 **codec** 文件夹放入 **FFmpeg-iOS/lib** 目录下
