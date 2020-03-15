#!/bin/bash

# does not work well

# *** Python pkg requirements ***
# yes | pip install pyyaml filelock
# *** Python pkg requirements ***

# *** UPDATE NDK FOLDER ***
# TFLite/MNN/ncnn can use newer ndk 
export ANDROID_NDK_HOME=/Users/weiwe/Library/Android/sdk/android-ndk-r20
export ANDROID_NDK=$ANDROID_NDK_HOME
export NDK_ROOT=$ANDROID_NDK_HOME
# MACE/Paddle-Lite need NDK r17c, update it after the ncnn benchmark
# *** UPDATE NDK FOLDER ***

SCRIPT_DIR=$PWD
OVERVIEW_LOG=$SCRIPT_DIR/overview.csv
TMP_DIR=$PWD/tmp
FRAMEWORKS_DIR=$PWD/frameworks
TF_ROOT="$FRAMEWORKS_DIR/tensorflow/"
MNN_ROOT="$FRAMEWORKS_DIR/MNN/"
NCNN_ROOT="$FRAMEWORKS_DIR/ncnn/"
MACE_ROOT="$FRAMEWORKS_DIR/mace/"
PADDLELITE_ROOT="$FRAMEWORKS_DIR/Paddle-Lite/"
# TFLite models from https://www.tensorflow.org/lite/guide/hosted_models
# MobileNet V1 1.0 224 - float + quantized
# MobileNet V2 1.0 224 - float
MODEL_DIR="$SCRIPT_DIR/models/"
TFLite_MODEL_DIR="$MODEL_DIR/tflite"
# MNN models are directly converted from TFLite models
MNN_MODEL_DIR="$MODEL_DIR/mnn"
# ncnn models from https://github.com/Tencent/ncnn/tree/master/benchmark and renamed
NCNN_MODEL_DIR="$MODEL_DIR/ncnn"
# MACE models from https://github.com/XiaoMi/mace-models and adapted
MACE_MODEL_DIR="$MODEL_DIR/mace"
# Paddle-Lite models from below and adapted
# https://paddle-inference-dist.bj.bcebos.com/PaddleLite/benchmark_0/benchmark_models.tgz
PADDLELITE_MODEL_DIR="$MODEL_DIR/paddle-lite"

DO_TFLITE=false
DO_MNN=false
DO_NCNN=false
DO_MACE=true
DO_PADDLELITE=false

REUSE_BINARY=true

MODELS="mobilenet_v1_1.0_224 mobilenet_v2_1.0_224"
RUN_THREADS=4
RUN_LOOP=50

# Set up folder and etc.
if [ ! -d $FRAMEWORKS_DIR ] 
then 
  mkdir -p $FRAMEWORKS_DIR
fi
if [ ! -d $TMP_DIR ] 
then 
  mkdir -p $TMP_DIR
fi
touch $OVERVIEW_LOG
rm $OVERVIEW_LOG
echo "Framework,$MODELS" | tr ' ' ',' > $OVERVIEW_LOG


# do TFLite benchmarks
# make sure you have manually run './configure' before running this script
if [ "$DO_TFLITE" = "true" ]
then
  BENCHMARK_BINARY="bazel-bin/tensorflow/lite/tools/benchmark/benchmark_model"
  if [ ! -d $TF_ROOT ] 
  then 
    git clone https://github.com/tensorflow/tensorflow.git $TF_ROOT
  fi 
  cd $TF_ROOT
  if [ "$REUSE_BINARY" = "false" ]
  then
    git checkout master
    git pull
    bazel clean
    bazel build -c opt \
      --config=android_arm64 \
      tensorflow/lite/tools/benchmark:benchmark_model
  fi
  adb push $BENCHMARK_BINARY /data/local/tmp
  #adb push /Users/weiwe/Desktop/project-src/tensorflow/$BENCHMARK_BINARY /data/local/tmp
  adb push $TFLite_MODEL_DIR/*.tflite /data/local/tmp
  rm -rf $TMP_DIR/*.log
  echo -n "TFLite(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
  for i in `echo $MODELS`; 
  do
    echo $i
    adb shell /data/local/tmp/benchmark_model \
    --graph=/data/local/tmp/$i.tflite \
    --num_threads=$RUN_THREADS --num_runs=$RUN_LOOP --use_gpu=true > $TMP_DIR/tflite.log
    grep 'Average inference timings in us' $TMP_DIR/tflite.log | awk '{print $NF/1000}' | tr '\n' ',' >> $OVERVIEW_LOG
  done
  echo >> $OVERVIEW_LOG
  BENCHMARK_BINARY=""
fi

# do MNN benchmarks
# Require flatbuf 'flatc' be in PATH
if [ "$DO_MNN" = "true" ]
then
  if [ ! -d $MNN_ROOT ] 
  then 
    git clone https://github.com/alibaba/MNN.git $MNN_ROOT
  fi 
  cd $MNN_ROOT/schema && ./generate.sh
  cd $MNN_ROOT/benchmark
  if [ "$REUSE_BINARY" = "false" ]
  then
    git reset --hard
    git clean -xdf
    git checkout master
    git pull
    # bug workaround
    #git checkout 2326a763d63a63622fcc0974f219f50486a2d41e
  fi
  sed -i '.bak' s%^BENCHMARK_MODEL_DIR.*%BENCHMARK_MODEL_DIR=$MNN_MODEL_DIR%g bench_android.sh
  # sed -i '.bak' s%^VULKAN=.*%VULKAN=\"OFF\"%g bench_android.sh   
  # sed -i '.bak' s%^OPENCL=.*%OPENCL=\"OFF\"%g bench_android.sh
  # sed -i '.bak' s%^OPENGL=.*%OPENGL=\"OFF\"%g bench_android.sh
  sed -i '.bak' "s/\$RUN_LOOP\ \$FORWARD_TYPE/\$RUN_LOOP \$FORWARD_TYPE $RUN_THREADS/g" bench_android.sh
  sed -i '.bak' s%RUN_LOOP=.*%RUN_LOOP=$RUN_LOOP%g bench_android.sh
  #disable Vulkan runs
  sed -i '.bak' '/RUN_LOOP 7 2/d' bench_android.sh
  touch benchmark.txt
  rm -rf benchmark.txt
  ./bench_android.sh -64 -p
  echo -n "MNN(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
  # awk magic to swap 1st and 2nd line because MNN reads models out of order
  grep 'max.*min.*avg' benchmark.txt | sort | awk 'NR%2{x=$0;next}{print $0"\n"x;}END{if(NR%2)print;}' | awk '{print $NF}' | sed s/ms//g | tr '\n' ',' >> $OVERVIEW_LOG
  echo >> $OVERVIEW_LOG
  BENCHMARK_BINARY=""
fi 

# do ncnn benchmarks
if [ "$DO_NCNN" = "true" ]
then
  BENCHMARK_BINARY="./benchmark/benchncnn"
  if [ ! -d $NCNN_ROOT ] 
  then 
    git clone https://github.com/Tencent/ncnn.git $NCNN_ROOT
  fi 
  cd $NCNN_ROOT
  if [ "$REUSE_BINARY" = "false" ]
  then
    git reset --hard
    git clean -xdf
    git checkout master
    git pull
    cp $SCRIPT_DIR/benchncnn.cpp benchmark/benchncnn.cpp
    mkdir -p build-android-aarch64
    cd build-android-aarch64
    # VULKAN SDK required
    export VULKAN_SDK=/Users/weiwe/Desktop/vulkansdk-macos-1.2.131.2/macOS
    cmake -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI="arm64-v8a" \
        -DANDROID_PLATFORM=android-24 -DNCNN_VULKAN=ON ..
    make -j8
  fi
  adb push $BENCHMARK_BINARY /data/local/tmp/
  adb push $NCNN_MODEL_DIR/*.param /data/local/tmp/
  # 0 means GPU
  adb shell /data/local/tmp/benchncnn $RUN_LOOP $RUN_THREADS 2 0 >& $TMP_DIR/ncnn.log
  echo -n "ncnn(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
  grep 'min.*max.*avg' $TMP_DIR/ncnn.log | tail -2 | awk '{print $NF}' | tr '\n' ',' >> $OVERVIEW_LOG
  echo >> $OVERVIEW_LOG
  BENCHMARK_BINARY=""
fi

# do MACE benchmark
# make sure proxy is on; since MACE download a bunch of models
if [ "$DO_MACE" = "true" ]
then
  # *** UPDATE NDK/bazel FOLDER ***
  # MACE/Paddle-Lite need NDK r17c
  export ANDROID_NDK_HOME=/Users/weiwe/Library/Android/sdk/android-ndk-r17c
  export ANDROID_NDK=$ANDROID_NDK_HOME
  export NDK_ROOT=$ANDROID_NDK_HOME
  export BAZEL_VERSION="0.12.0"
  # *** UPDATE NDK/bazel FOLDER ***
  if [ ! -d $MACE_ROOT ] 
  then 
    git clone https://github.com/XiaoMi/mace.git $MACE_ROOT
  fi 
  cd $MACE_ROOT
  if [ "$REUSE_BINARY" = "false" ]
  then
    git reset --hard
    git clean -xdf
    git checkout master
    git pull
    RUNTIME=CPU bash tools/cmake/cmake-build-arm64-v8a.sh
  fi
  touch $TMP_DIR/mace.log
  rm $TMP_DIR/mace.log
  echo -n "MACE(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
  cp -R $MACE_MODEL_DIR/build/* ./build/
  for i in `echo $MODELS`; do
    USE_BAZEL_VERSION=$BAZEL_VERSION python tools/python/run_model.py  \
      --config $MACE_MODEL_DIR/$i.yml   \
      --benchmark   \
      --target_abi=arm64-v8a   \
      --omp_num_threads=$RUN_THREADS   \
      --round=$RUN_LOOP   \
      --runtime=gpu > $TMP_DIR/mace.log
    grep -A 4 "Summary of Ops' Stat" $TMP_DIR/mace.log | tail -1 | cut -d\| -f 7 | tr '\n' ',' >> $OVERVIEW_LOG
  done
  echo >> $OVERVIEW_LOG
fi

# do Paddle-Lite benchmark
if [ "$DO_PADDLELITE" = "true" ]
then
  # *** UPDATE NDK/bazel/cmake FOLDER ***
  # MACE/Paddle-Lite need NDK r17c
  export ANDROID_NDK_HOME=/Users/weiwe/Library/Android/sdk/android-ndk-r17c
  export ANDROID_NDK=$ANDROID_NDK_HOME
  export NDK_ROOT=$ANDROID_NDK_HOME
  export BAZEL_VERSION="0.12.0"
  # *** override cmake due to a limitation ***
  # https://github.com/PaddlePaddle/Paddle-Lite/issues/2950
  export PATH=/Users/weiwe/Utils/cmake-3.10.3-Darwin-x86_64/CMake.app/Contents/bin:$PATH
  # *** UPDATE NDK FOLDER ***

  if [ ! -d $PADDLELITE_ROOT ] 
  then 
    git clone https://github.com/PaddlePaddle/Paddle-Lite.git $PADDLELITE_ROOT
  fi 
  cd $PADDLELITE_ROOT
  if [ "$REUSE_BINARY" = "false" ]
  then
    git reset --hard
    git clean -xdf
    git checkout develop
    git pull
    # strangly it errors out if compiled twice
    ./lite/tools/ci_build.sh  \
      --arm_os="android" \
      --arm_abi="armv8" \
      --arm_lang="clang "  \
      build_arm
  fi
  # script is from https://paddle-inference-dist.bj.bcebos.com/PaddleLite/benchmark_0/benchmark.sh
  cp $SCRIPT_DIR/benchpaddlelite.sh ./
  sed -i '.bak' "s/^NUM_THREADS_LIST=.*/NUM_THREADS_LIST=\($RUN_THREADS\)/g" benchpaddlelite.sh
  sed -i '.bak' "s/^REPEATS=.*/REPEATS=$RUN_LOOP/g" benchpaddlelite.sh
  mkdir -p ./benchmark_models
  cp -R $PADDLELITE_MODEL_DIR/* ./benchmark_models/
  cp build.lite.android.armv8.clang/lite/api/benchmark_bin .
  sh ./benchpaddlelite.sh ./benchmark_bin  \
    ./benchmark_models paddle-lite.log true | tee $TMP_DIR/paddle-lite.log
  # No quantized mobilenet v1 model yet
  echo -n "Paddle-Lite(`git rev-parse --short HEAD`),0," >> $OVERVIEW_LOG
  grep 'min.*max.*average' $TMP_DIR/paddle-lite.log | awk '{print $NF}' | tr '\n' ',' >> $OVERVIEW_LOG
  echo >> $OVERVIEW_LOG
fi

# do a final cleanup
sed -i '.bak' "s/,$//g" $OVERVIEW_LOG