# syntax=docker/dockerfile:1.7
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# bimg builds with GENie from the sibling `bx` repo. Bake it into the image (pinned commit) so
# mayhem/build.sh re-runs fully offline (the PATCH-tier air-gapped re-run).
ARG BX_COMMIT=9e3fadf6f11380031486be704d2ff46ca143664f
USER root
RUN git clone https://github.com/bkaradzic/bx /opt/bx \
    && git -C /opt/bx checkout -q "$BX_COMMIT" \
    && chown -R 2000:2000 /opt/bx
ENV BX_DIR=/opt/bx

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
