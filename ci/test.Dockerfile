ARG BASE=cvsnt-build
FROM ${BASE}
RUN dnf install -y python39 diffutils findutils && dnf clean all \
 && groupadd -g 52 cvs && useradd -u 52 -g 52 -d /work -M cvs
