FROM alpine:3.7

WORKDIR /root

ENTRYPOINT perl -I /root/lib/ /root/bin/map_network_sgs
CMD [ 'eu-west-1' ]

COPY . /root

RUN apk update \
    && apk add --no-cache curl wget make gcc musl-dev perl-dev graphviz-dev\
    && apk add --no-cache perl-net-ssleay perl-xml-simple perl-moose perl-config-inifiles perl-getopt-long perl-data-compare perl-datetime perl-json-maybexs perl-path-tiny perl-dbi perl-date-simple \
    && curl -LO http://www.cpan.org/authors/id/M/MI/MIYAGAWA/App-cpanminus-1.7043.tar.gz \
    && echo '68a06f7da80882a95bc02c92c7ee305846fb6ab648cf83678ea945e44ad65c65 *App-cpanminus-1.7043.tar.gz' | sha256sum -c - \
    && tar -xzf App-cpanminus-1.7043.tar.gz \
    && cd App-cpanminus-1.7043 \
    && perl bin/cpanm . \
    && cd /root \
    && cpanm -n --installdeps . \
    && cpanm -n Devel::OverloadInfo \
    && apk del make gcc musl-dev perl-dev \
    && rm -fr cpanm /root/.cpanm /tmp/* App-cpanminus-1.7043*
