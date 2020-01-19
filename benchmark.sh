#!/bin/bash

SCRIPT_DIR=$PWD
UPPER_LEVEL=$PWD/..
OVERVIEW_LOG=$SCRIPT_DIR/overview.csv
echo $OVERVIEW_LOG
TF_ROOT="$UPPER_LEVEL/tensorflow/"
MNN_ROOT="$UPPER_LEVEL/MNN/"
NCNN_ROOT="$UPPER_LEVEL/ncnn/"
# TFLite models from https://www.tensorflow.org/lite/guide/hosted_models
# only include models that all framework can support:
# MobileNet V1 1.0 224 - float + quantized
# MobileNet V2 1.0 224 - float + quantized
TFLite_MODEL_DIR="$UPPER_LEVEL/benchmark/models/tflite"
# MNN models are directly converted from TFLite models
MNN_MODEL_DIR="$UPPER_LEVEL/benchmark/models/mnn"
# ncnn models from https://github.com/Tencent/ncnn/tree/master/benchmark and renamed
NCNN_MODEL_DIR="$UPPER_LEVEL/benchmark/models/ncnn"

export ANDROID_NDK=/Users/weiwe/Library/Android/sdk/ndk/android-ndk-r20/
MODELS="mobilenet_v1_1.0_224_quant mobilenet_v1_1.0_224 mobilenet_v2_1.0_224"
RUN_THREADS=4
RUN_LOOP=50

# do TFLite benchmarks
cd $TF_ROOT
git checkout master
git pull
bazel clean
bazel build -c opt \
  --config=android_arm \
  tensorflow/lite/tools/benchmark:benchmark_model

adb push bazel-bin/tensorflow/lite/tools/benchmark/benchmark_model /data/local/tmp
adb push $TFLite_MODEL_DIR/*.tflite /data/local/tmp

touch $OVERVIEW_LOG
rm -rf $SCRIPT_DIR/*.log

for i in `echo $MODELS`; 
do
  echo $i
  adb shell /data/local/tmp/benchmark_model \
  --graph=/data/local/tmp/$i.tflite \
  --num_threads=4 > $SCRIPT_DIR/tflite-$i.log
done

echo "Framework,$MODELS" | tr ' ' ',' > $OVERVIEW_LOG
echo -n "TFLite(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
grep 'Average inference timings in us' $SCRIPT_DIR/*.log | awk '{print $NF/1000}' | tr '\n' ',' >> $OVERVIEW_LOG
echo >> $OVERVIEW_LOG

# do MNN benchmarks
cd $MNN_ROOT/benchmark
git reset --hard
git clean -xdf
git checkout master
# build is broken for now
git checkout d93a15e52719ebc077854b32ee74232694ac1ef2
git pull
sed -i '.bak' s%^BENCHMARK_MODEL_DIR.*%BENCHMARK_MODEL_DIR=$MNN_MODEL_DIR%g bench_android.sh
sed -i '.bak' s%^VULKAN=.*%VULKAN=\"OFF\"%g bench_android.sh   
sed -i '.bak' s%^OPENCL=.*%OPENCL=\"OFF\"%g bench_android.sh
sed -i '.bak' s%^OPENGL=.*%OPENGL=\"OFF\"%g bench_android.sh
sed -i '.bak' s%RUN_LOOP=.*%RUN_LOOP=50%g bench_android.sh
#disable Vulkan runs
sed -i '.bak' '/RUN_LOOP 7 2/d' bench_android.sh
./bench_android.sh -64 -p
echo -n "MNN(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
grep 'max.*min.*avg' benchmark.txt | awk '{print $NF}' | sed s/ms//g | tr '\n' ',' >> $OVERVIEW_LOG
echo >> $OVERVIEW_LOG

# do ncnn benchmarks
cd $NCNN_ROOT
git reset --hard
git clean -xdf
git checkout master
git pull
cp $SCRIPT_DIR/benchncnn.cpp benchmark/benchncnn.cpp
mkdir -p build-android-aarch64
cd build-android-aarch64
cmake -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI="arm64-v8a" \
    -DANDROID_PLATFORM=android-21 ..
make -j8
adb push benchmark/benchncnn /data/local/tmp/
adb push $NCNN_MODEL_DIR/*.param /data/local/tmp/
adb shell /data/local/tmp/benchncnn $RUN_LOOP $RUN_THREADS 2 -1 >& ncnn.log
echo -n "ncnn(`git rev-parse --short HEAD`)," >> $OVERVIEW_LOG
grep 'min.*max.*avg' ncnn.log | awk '{print $NF}' | tr '\n' ',' >> $OVERVIEW_LOG
echo >> $OVERVIEW_LOG