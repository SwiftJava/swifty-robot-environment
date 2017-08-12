#!/bin/bash
#
# Called by gradle install to create scripts used in Android build.
# Scripts are kept in ~/.gradle/scripts and refered to in gradle source:
# gradle/src/main/groovy/net/zhuoweizhang/swiftandroid/SwiftAndroidPlugin.groovy
#

SWIFT_INSTALL="$(dirname $PWD)"
ARCH=`uname`

SCRIPTS=~/.gradle/scripts

export JAVA_HOME="${JAVA_HOME?-Please export JAVA_HOME}"

cat <<DOC &&

Running: $SWIFT_INSTALL/gradle/$0

This version of the gradle plugin inserts four scripts into the Android
build process. These autogenerate Swift code for any Java classes in a
directory "swiftbindings", build the swift, compile Swift for Android
and copy Swift standard lbaraies into the jniLibs directory.

Add the following to your project's "buildscript/dependencies"

        classpath 'net.zhuoweizhang:swiftandroid:1.0.0'

And add this to the module's build.gradle:

apply plugin: 'net.zhuoweizhang.swiftandroid'

Consult https://github.com/SwiftJava/swift-android-kotlin for details.

DOC

GLIBC_MODULEMAP="$SWIFT_INSTALL/usr/lib/swift/android/armv7/glibc.modulemap"
if [[ ! -f "$GLIBC_MODULEMAP.orig" ]]; then
    cp "$GLIBC_MODULEMAP" "$GLIBC_MODULEMAP.orig"
fi &&

sed -e s@/usr/local/android/ndk/platforms/android-21/arch-arm/@$SWIFT_INSTALL/ndk-android-21@ <"$GLIBC_MODULEMAP.orig" >"$GLIBC_MODULEMAP" &&

rm -f "$SWIFT_INSTALL/usr/bin/swift" &&
if [[ "$ARCH" == "Darwin" ]]; then
    ln -sf "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" "$SWIFT_INSTALL/usr/bin/swift"
else
    SWIFT="$(which swift)"
    if [[ "$SWIFT" == "" ]]; then
        echo
        echo "*** A swift binary needs to be in your \$PATH to proceed ***"
        echo
        exit 1
    fi
    ln -sf "$SWIFT" "$SWIFT_INSTALL/usr/bin/swift" &&
    ANDROID_GOLD_LINKER="/usr/bin/armv7-none-linux-android-ld.gold"
    if [[ ! -f "$ANDROID_GOLD_LINKER" ]]; then
        echo "Creaing link for $ANDROID_GOLD_LINKER..." &&
        sudo ln -sf "$SWIFT_INSTALL/usr/Linux/ld.gold" "$ANDROID_GOLD_LINKER"
    fi
fi &&

echo "Swift path selected:" && ls -l "$SWIFT_INSTALL/usr/bin/swift" && echo &&

mkdir -p $SCRIPTS && cd $SCRIPTS &&

cat <<SCRIPT >generate-swift.sh &&
#!/bin/bash
#
# Pre-build stage to regenerate swift source from bindings sources
# Also generates Swift proxy classes so it has to be pre-build
#

SWIFT_INSTALL="$SWIFT_INSTALL"
export PATH="\$SWIFT_INSTALL/usr/bin:\$PATH"
export SWIFT_EXEC=~/.gradle/scripts/swiftc-android.sh
export JAVA_HOME="$JAVA_HOME"

# compile genswift if required
if [[ ! -f /tmp/genswift/genswift.class ]]; then
    mkdir -p /tmp/genswift &&
    cd "\$SWIFT_INSTALL/gradle/src/main/scripts" &&
    $JAVA_HOME/bin/javac -d /tmp/genswift genswift.java &&
    cd - >/dev/null
fi &&

# regenerate swift for any bindings if a source file has changed
# yes, this is perl...
cd ../java && (find . -type f | grep /swiftbindings/ | perl <(cat <<'PERL'
use strict;
while ( my \$source = <STDIN> ) {
    chomp \$source;
    (my \$class = "/tmp/bindings/\$source") =~ s/\.java\$/.class/;
    # Binding source more recent than when it was last generated?
    exit 1 if (stat \$source)[9] > (stat \$class)[9];
}
# Bindings up to date
PERL
)) || (rm -rf /tmp/bindings && mkdir /tmp/bindings && \
\$JAVA_HOME/bin/javac -parameters -d /tmp/bindings \`find . -type f | grep /swiftbindings/\` && \
cd - >/dev/null && cd /tmp/bindings && \
\$JAVA_HOME/bin/jar cf bindings.jar \`find . -type f -name '*.class'\` && cd - >/dev/null && \
\$JAVA_HOME/bin/jar tf /tmp/bindings/bindings.jar | grep /swiftbindings/ | sed 's@\\.class\$@@' | \
\$JAVA_HOME/bin/java -cp /tmp/genswift:/tmp/bindings/bindings.jar genswift \
'java/lang|java/util|java/sql' Sources ../java)

SCRIPT

cat <<SCRIPT >swift-build.sh &&
#!/bin/bash
#
# Script to call swift build with PATH set correctly
#

SWIFT_INSTALL="$SWIFT_INSTALL"
export PATH="\$SWIFT_INSTALL/usr/bin:\$PATH"
export SWIFT_EXEC=~/.gradle/scripts/swiftc-android.sh

swift build

SCRIPT

cat <<SCRIPT >swiftc-android.sh &&
#!/bin/bash
#
# Substitutes in for swiftc to compile package and build Android sources
#

SWIFT_INSTALL="$SWIFT_INSTALL"
export PATH="\$SWIFT_INSTALL/usr/$ARCH:\$PATH:$(dirname `which swift`)"

if [[ "\$*" =~ " -fileno " ]]; then
    swift "\$@" || (echo "*** Error executing: \$0 \$@" && exit 1)
    exit $?
fi

ARGS=\$(echo "\$*" | sed -E "s@-target [^[:space:]]+ -sdk /[^[:space:]]* (-F /[^[:space:]]* )?@@")

if [[ "\$*" =~ " -emit-executable " ]]; then
    LINKER_ARGS="-Xlinker -shared -Xlinker -export-dynamic"
fi

swiftc -target armv7-none-linux-androideabi \\
    -sdk "\$SWIFT_INSTALL/ndk-android-21" -L "\$SWIFT_INSTALL/usr/$ARCH" \\
    \$LINKER_ARGS \$ARGS || (echo "*** Error executing: \$0 \$LINKER_ARGS \$ARGS" && exit 1)

SCRIPT

cat <<SCRIPT >copy-libraries.sh &&
#!/bin/bash
#
# Copy swift libraries for inclusion in app APK
#

DESTINATION="\$1"
SWIFT_INSTALL="$SWIFT_INSTALL"

mkdir -p "\$DESTINATION" && cd "\$DESTINATION" &&
rsync -u "\$SWIFT_INSTALL"/usr/lib/swift/android/*.so . &&
rm -f *Unittest*

SCRIPT

chmod +x {generate-swift,swift-build,swiftc-android,copy-libraries}.sh &&
echo Created: $SCRIPTS/{generate-swift,swift-build,swiftc-android,copy-libraries}.sh &&
echo

