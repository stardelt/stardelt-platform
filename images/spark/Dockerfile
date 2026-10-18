# syntax=docker/dockerfile:1.7
# stardelt's Spark image: Apache Spark 4.1 (Spark Connect server) plus the
# Iceberg runtime and AWS bundle that the upstream image does not ship.
#
# Why a derived image instead of `spark.jars.packages`: the platform installs
# from pinned artifacts, not from Maven Central at pod startup (master spec §4,
# "sovereign by default"). The jars are fetched once, at image build time,
# verified against the SHA-512 checksums Maven Central publishes, and then
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
ADD --checksum=sha512:ac1e2cb00970309f0c6bf241fabf334aef373c1f3e3b443181d429d5f2c0903ace47df9cfc1d55c95807a096cf405ae0a8868831b9e9eb5696dfdb6380587f38 \
    https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-4.1_2.13/${ICEBERG_VERSION}/iceberg-spark-runtime-4.1_2.13-${ICEBERG_VERSION}.jar \
    /opt/spark/jars/iceberg-spark-runtime.jar

# S3FileIO and the AWS SDK v2 it needs. The REST catalog is configured without
# vended credentials (Lakekeeper's `allowall` dev shape), so the client signs
# its own S3 requests with the credentials from Secret stardelt-s3-creds.
ADD --checksum=sha512:b01456f80142c8837004e31329a0f40db8a9d44917a4a694cb7d8d6d3a68cb20c61e6f7788fa1bdcb95c0edf724322b49667d6f9ef60fc9cc46da5c24ce5c7de \
    https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
    /opt/spark/jars/iceberg-aws-bundle.jar

# Starts the Connect server in the foreground and fills in the one address that
# only exists at runtime (the driver's pod IP). See the file for the details.
COPY spark-connect-entrypoint.sh /opt/spark/bin/stardelt-connect-server
RUN chmod 0755 /opt/spark/bin/stardelt-connect-server

# The upstream image runs as the `spark` user (uid 185); keep it that way.
USER 185
