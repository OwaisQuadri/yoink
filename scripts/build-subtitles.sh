#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

vendor=vendor/whisper
revision=4979e04f5dcaccb36057e059bbaed8a2f5288315
archive_sha=ec8e33f4c838ed459ad0a23da255c0262f150a6f54839a17e504ddf1495305d5
model_revision=5359861c739e955e79d9a303bcbc70fb988958b1
model_sha=60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe
mkdir -p $vendor
if [[ ! -f $vendor/source-$revision/CMakeLists.txt ]]; then
  curl -fL "https://github.com/ggml-org/whisper.cpp/archive/$revision.tar.gz" -o $vendor/source.tar.gz
  echo "$archive_sha  $vendor/source.tar.gz" | shasum -a 256 -c -
  mkdir -p $vendor/source-$revision
  tar -xzf $vendor/source.tar.gz -C $vendor/source-$revision --strip-components=1
fi
if [[ ! -f $vendor/ggml-base.bin ]]; then
  curl -fL "https://huggingface.co/ggerganov/whisper.cpp/resolve/$model_revision/ggml-base.bin" -o $vendor/ggml-base.bin.part
  echo "$model_sha  $vendor/ggml-base.bin.part" | shasum -a 256 -c -
  mv $vendor/ggml-base.bin.part $vendor/ggml-base.bin
fi
echo "$model_sha  $vendor/ggml-base.bin" | shasum -a 256 -c -
/usr/bin/perl -0pi -e 's/f->stream_start \+ loc >= f->stream_end \|\| f->stream_start \+ loc < f->stream_start/loc >= (size_t) (f->stream_end - f->stream_start)/g' $vendor/source-$revision/examples/stb_vorbis.c
clang -Werror -fsanitize=undefined -I $vendor/source-$revision/examples Tests/Dependencies/stb-vorbis-bounds.c -o $vendor/test-bounds
$vendor/test-bounds
for arch in arm64 x86_64; do
  cmake -Werror=author -Werror=deprecated -S $vendor/source-$revision -B $vendor/build-$arch \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10 -DGGML_CCACHE=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-Werror -DCMAKE_CXX_FLAGS=-Werror -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_FATAL_WARNINGS=ON -DGGML_FATAL_WARNINGS=ON
  cmake --build $vendor/build-$arch --config Release --target whisper-cli -j 8
done
lipo -create $vendor/build-arm64/bin/whisper-cli $vendor/build-x86_64/bin/whisper-cli -output $vendor/whisper-cli
cp $vendor/source-$revision/LICENSE $vendor/WHISPER-LICENSE
