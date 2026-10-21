# syntax=docker/dockerfile:1.7
# stardelt's Spark image: Apache Spark 4.1 (Spark Connect server) plus the
# Iceberg runtime and AWS bundle that the upstream image does not ship.
#
# Why a derived image instead of `spark.jars.packages`: the platform installs
# from pinned artifacts, not from Maven Central at pod startup (master spec §4,
# "sovereign by default"). The jars are fetched once, at image build time,
# verified against the SHA-256 checksums Maven Central publishes, and then
# delivered by the registry like every other layer.
#
# Built by .github/workflows/image.yml; a push to main publishes `dev` and
# `sha-<short>`. Resolve the tag to a digest when rolling the dev cluster
# (`make pin-images`, which also updates manifests/spark.yaml).
#
# 4.1.3 is the current Spark 4.1 release and 1.12.0 the Iceberg release that
# publishes `iceberg-spark-runtime-4.1_2.13`. Renovate updates the base image;
# bump ICEBERG_VERSION by hand and keep both on the same Spark minor.
FROM apache/spark:4.1.3-scala2.13-java17-python3-ubuntu@sha256:9b0a6c2c860f5e7d18dd5270286fef32a09c7f5a7e2b0dbe5642de8a3a02ab3e

ARG ICEBERG_VERSION=1.12.0

USER root

# Iceberg's Spark runtime: catalog implementations, the Spark extensions, and
# the Iceberg SQL syntax extension Spark loads through spark.sql.extensions.
# A mismatched Scala/Spark ABI is the common failure here, which is why the
# artifact name carries both (`-4.1_2.13-`) and the version is pinned.
ADD --checksum=sha256:3123c3798af642dd537230923548e013ef41cc28b6626e5225808cf5670a0f82 \
    https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-4.1_2.13/${ICEBERG_VERSION}/iceberg-spark-runtime-4.1_2.13-${ICEBERG_VERSION}.jar \
    /opt/spark/jars/iceberg-spark-runtime.jar

# S3FileIO and the AWS SDK v2 it needs. The REST catalog is configured without
# vended credentials (Lakekeeper's `allowall` dev shape), so the client signs
# its own S3 requests with the credentials from Secret stardelt-s3-creds.
ADD --checksum=sha256:dd7e49ffa4ac9b215bed846581991259e3aec9bb2fa08d6cec029c46cd66d957 \
    https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
    /opt/spark/jars/iceberg-aws-bundle.jar

# Hadoop's S3A filesystem, so a notebook can read *public* S3 buckets with
# `s3a://` (and `s3://`, mapped to the same class in manifests/spark.yaml).
# The upstream image ships hadoop-client 3.4.2 without hadoop-aws, so
# org.apache.hadoop.fs.s3a.S3AFileSystem does not exist. hadoop-aws must match
# that client version exactly. S3A is pinned to the *anonymous* credentials
# provider in manifests/spark.yaml: these jars never see the platform's S3 key —
# that key belongs to Iceberg's S3FileIO, which is a different client.
#
# hadoop-aws 3.4.2 needs AWS SDK v2 at the version its pom names
# (`aws-java-sdk-v2.version` of hadoop-project 3.4.2 = 2.29.52), shipped as the
# single `software.amazon.awssdk:bundle` artifact; a different SDK version fails
# at the first S3 call. The bundle is ~612 MiB uncompressed (under the 700 MiB
# gate in platform#347; the per-module alternative was not needed).
#
# `--chmod=0644` on these two ADDs, not a `chmod` in the RUN below: the bundle
# is large enough that a chmod would copy the whole file up into a second
# ~536 MiB layer. The RUN still covers the Iceberg jars. Apache-2.0.
ADD --checksum=sha256:d2d24e6b715b5656b9d238bf13b6682a07e2004dd36aad74a73aeb854319f4d9 --chmod=0644 \
    https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.4.2/hadoop-aws-3.4.2.jar \
    /opt/spark/jars/hadoop-aws-3.4.2.jar
ADD --checksum=sha256:62638f33045690c6bc5e496b54b0b2e89a9ad38cbedacdf6e017fea6bc85f55c --chmod=0644 \
    https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.29.52/bundle-2.29.52.jar \
    /opt/spark/jars/bundle-2.29.52.jar

# `ADD <url>` lands the file as mode 0600; the container runs as the `spark`
# user (uid 185), so make the jars world-readable or the JVM cannot load them.
RUN chmod 0644 /opt/spark/jars/iceberg-spark-runtime.jar /opt/spark/jars/iceberg-aws-bundle.jar \
    /opt/spark/jars/hadoop-aws-3.4.2.jar /opt/spark/jars/bundle-2.29.52.jar

# Starts the Connect server in the foreground and fills in the one address that
# only exists at runtime (the driver's pod IP). See the file for the details.
COPY spark-connect-entrypoint.sh /opt/spark/bin/stardelt-connect-server
RUN chmod 0755 /opt/spark/bin/stardelt-connect-server

# The upstream image runs as the `spark` user (uid 185); keep it that way.
USER 185
