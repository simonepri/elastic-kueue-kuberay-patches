# Overlay the patched Ray Python sources from a sparse upstream checkout onto the stock Ray image.
# The build context is third_party/ray, which holds only the files patches/ray touches.

ARG BASE_IMAGE=rayproject/ray:2.59.0-py313

FROM ${BASE_IMAGE}
COPY --chown=1000:100 python/ray/ /tmp/ray-patch/
RUN cp -R /tmp/ray-patch/. "$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/ray/" \
    && rm -rf /tmp/ray-patch
