#!/bin/sh

# directories
FF_VERSION="4.0"
if [[ $FFMPEG_VERSION != "" ]]; then
  FF_VERSION=$FFMPEG_VERSION
fi
SOURCE="ffmpeg-$FF_VERSION"
FAT="FFmpeg-iOS"

SCRATCH="scratch"
# must be an absolute path
THIN=`pwd`/"thin"

# absolute path to x264 library
#X264=`pwd`/fat-x264

OPENCORE_AMRNB=`pwd`/codec/opencore-amr-ios
FDK_AAC=`pwd`/codec/fdk-aac-ios

CONFIGURE_FLAGS="--enable-cross-compile --disable-debug --disable-programs \
                 --disable-doc --enable-pic \
                 --enable-small --disable-avdevice --disable-avfilter --disable-network \
                 --disable-encoders --disable-decoders \
                 --enable-encoder=libfdk_aac --enable-decoder=libfdk_aac \
                 --enable-encoder=libopencore_amrnb --enable-decoder=libopencore_amrnb \
                 --enable-decoder=libopencore_amrwb \
                 \
                 --enable-encoder=pcm_f32be --enable-decoder=pcm_f32be \
				 --enable-encoder=pcm_f32le --enable-decoder=pcm_f32le \
				 --enable-encoder=pcm_f64be --enable-decoder=pcm_f64be \
				 --enable-encoder=pcm_f64le --enable-decoder=pcm_f64le \
				 --enable-encoder=pcm_lxf --enable-decoder=pcm_lxf \
				 --enable-encoder=pcm_mulaw --enable-decoder=pcm_mulaw \
				 --enable-encoder=pcm_s16be --enable-decoder=pcm_s16be \
				 --enable-encoder=pcm_s16be_planar --enable-decoder=pcm_s16be_planar \
				 --enable-encoder=pcm_s16le --enable-decoder=pcm_s16le \
				 --enable-encoder=pcm_s16le_planar --enable-decoder=pcm_s16le_planar \
				 --enable-encoder=pcm_s24be --enable-decoder=pcm_s24be \
				 --enable-encoder=pcm_s24daud --enable-decoder=pcm_s24daud \
				 --enable-encoder=pcm_s24le --enable-decoder=pcm_s24le \
				 --enable-encoder=pcm_s24le_planar --enable-decoder=pcm_s24le_planar \
				 --enable-encoder=pcm_s32be --enable-decoder=pcm_s32be \
				 --enable-encoder=pcm_s32le --enable-decoder=pcm_s32le \
				 --enable-encoder=pcm_s32le_planar --enable-decoder=pcm_s32le_planar \
				 --enable-encoder=pcm_s64be --enable-decoder=pcm_s64be \
				 --enable-encoder=pcm_s64le --enable-decoder=pcm_s64le \
				 --enable-encoder=pcm_s8 --enable-decoder=pcm_s8 \
				 --enable-encoder=pcm_s8_planar --enable-decoder=pcm_s8_planar \
				 --enable-encoder=pcm_u16be --enable-decoder=pcm_u16be \
				 --enable-encoder=pcm_u16le --enable-decoder=pcm_u16le \
				 --enable-encoder=pcm_u24be --enable-decoder=pcm_u24be \
				 --enable-encoder=pcm_u24le --enable-decoder=pcm_u24le \
				 --enable-encoder=pcm_u32be --enable-decoder=pcm_u32be \
				 --enable-encoder=pcm_u32le --enable-decoder=pcm_u32le \
				 --enable-encoder=pcm_u8 --enable-decoder=pcm_u8"

if [ "$X264" ]
then
	CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-gpl --enable-libx264"
fi

if [ "$FDK_AAC" ]
then
	CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-libfdk-aac --enable-nonfree"
fi

if [ "$OPENCORE_AMRNB" ]
then
    CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-version3"
fi

# avresample
#CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-avresample"

ARCHS="arm64 armv7 armv7s x86_64 i386"

COMPILE="y"
LIPO="y"

DEPLOYMENT_TARGET="8.0"

if [ "$*" ]
then
	if [ "$*" = "lipo" ]
	then
		# skip compile
		COMPILE=
	else
		ARCHS="$*"
		if [ $# -eq 1 ]
		then
			# skip lipo
			LIPO=
		fi
	fi
fi

if [ "$COMPILE" ]
then
	if [ ! `which yasm` ]
	then
		echo 'Yasm not found'
		if [ ! `which brew` ]
		then
			echo 'Homebrew not found. Trying to install...'
                        ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)" \
				|| exit 1
		fi
		echo 'Trying to install Yasm...'
		brew install yasm || exit 1
	fi
	if [ ! `which gas-preprocessor.pl` ]
	then
		echo 'gas-preprocessor.pl not found. Trying to install...'
		(curl -L https://github.com/libav/gas-preprocessor/raw/master/gas-preprocessor.pl \
			-o /usr/local/bin/gas-preprocessor.pl \
			&& chmod +x /usr/local/bin/gas-preprocessor.pl) \
			|| exit 1
	fi

	if [ ! -r $SOURCE ]
	then
		echo 'FFmpeg source not found. Trying to download...'
		curl http://www.ffmpeg.org/releases/$SOURCE.tar.bz2 | tar xj \
			|| exit 1
	fi

	CWD=`pwd`
	for ARCH in $ARCHS
	do
		echo "building $ARCH..."
		mkdir -p "$SCRATCH/$ARCH"
		cd "$SCRATCH/$ARCH"

		CFLAGS="-arch $ARCH"
		if [ "$ARCH" = "i386" -o "$ARCH" = "x86_64" ]
		then
		    PLATFORM="iPhoneSimulator"
		    CFLAGS="$CFLAGS -mios-simulator-version-min=$DEPLOYMENT_TARGET"
		else
		    PLATFORM="iPhoneOS"
		    CFLAGS="$CFLAGS -mios-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
		    if [ "$ARCH" = "arm64" ]
		    then
		        EXPORT="GASPP_FIX_XCODE5=1"
		    fi
		fi

		XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
		CC="xcrun -sdk $XCRUN_SDK clang"

		# force "configure" to use "gas-preprocessor.pl" (FFmpeg 3.3)
		if [ "$ARCH" = "arm64" ]
		then
		    AS="gas-preprocessor.pl -arch aarch64 -- $CC"
		else
		    AS="gas-preprocessor.pl -- $CC"
		fi

		CXXFLAGS="$CFLAGS"
		LDFLAGS="$CFLAGS"
		if [ "$X264" ]
		then
			CFLAGS="$CFLAGS -I$X264/include"
			LDFLAGS="$LDFLAGS -L$X264/lib"
		fi
		if [ "$FDK_AAC" ]
		then
			CFLAGS="$CFLAGS -I$FDK_AAC/include"
			LDFLAGS="$LDFLAGS -L$FDK_AAC/lib"
		fi
        if [ "$OPENCORE_AMRNB" ]
        then
            CFLAGS="$CFLAGS -I$OPENCORE_AMRNB/include"
            LDFLAGS="$LDFLAGS -L$OPENCORE_AMRNB/lib"
        fi

		TMPDIR=${TMPDIR/%\/} $CWD/$SOURCE/configure \
		    --target-os=darwin \
		    --arch=$ARCH \
		    --cc="$CC" \
		    --as="$AS" \
		    $CONFIGURE_FLAGS \
		    --extra-cflags="$CFLAGS" \
		    --extra-ldflags="$LDFLAGS" \
		    --prefix="$THIN/$ARCH" \
		|| exit 1

		make -j3 install $EXPORT || exit 1
		cd $CWD
	done
fi

if [ "$LIPO" ]
then
	echo "building fat binaries..."
	mkdir -p $FAT/lib
	set - $ARCHS
	CWD=`pwd`
	cd $THIN/$1/lib
	for LIB in *.a
	do
		cd $CWD
		echo lipo -create `find $THIN -name $LIB` -output $FAT/lib/$LIB 1>&2
		lipo -create `find $THIN -name $LIB` -output $FAT/lib/$LIB || exit 1
	done

	cd $CWD
	cp -rf $THIN/$1/include $FAT
fi

echo Done
