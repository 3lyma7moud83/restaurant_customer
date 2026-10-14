ack?$media,redirect=noop-1s.mp4,domain=safeframe.googlesyndication.com
safeframe.googlesyndication.com##.left-container
! https://github.com/AdguardTeam/AdguardFilters/issues/156301
@@||g.doubleclick.net/pagead/images/gmob/close-circle-30x30.png$image,domain=safeframe.googlesyndication.com
@@||gstatic.com/admanager/outstream/rewarded_web_video_$script,domain=safeframe.googlesyndication.com
@@||google-analytics.com/analytics.js$domain=bihann.com|nehannn.com

! https://github.com/easylist/easylist/commit/c1e5cea211d41c5547f58321e5dae56ac834fce0
||tercept.com^$badfilter
||tercept.com^$3p

! broken sportschau.de live stream
! https://github.com/AdguardTeam/AdguardFilters/issues/145948
||wdr.de/*/tracker/tracker.min.js$script,redirect=noop.js,domain=sportschau.de
@@||de-config.sensic.net/sui-connector.js$script,domain=sportschau.de

! unbreak https://uiz.io/QfCH from https://github.com/AdguardTeam/AdguardFilters/issues/54339
@@||bigappboi.com/captchalocker/js/popup.js.php
@@||bigappboi.com/cp/js/captcha.js.php

! fix video https://www.pussyspace.com/live/anna_lus/
! https://github.com/AdguardTeam/AdguardFilters/issues/143346
@@||chaturbate.com/in/$frame,domain=cbhours.com|pussyspace.*

! https://www.reddit.com/r/uBlockOrigin/comments/purjil/ubo_prevent_video_from_loading_on/
@@||tra.scds.pmdstatic.net/advertising-core/$script,domain=businessinsider.fr

! https://github.com/uBlockOrigin/uAssets/issues/10078
@@||googletagmanager.com/gtm.js$script,domain=gall.nl

! https://www.reddit.com/r/uBlockOrigin/comments/pwi2p7/wondrium_what_am_i_doing_wrong/
@@||wondrium.com/static/version1632408975/frontend/Wondrium/default/en_US/js/analytics.js$script,1p

! https://github.com/uBlockOrigin/uAssets/issues/10093
xunta.gal#@##anuncio

! https://www.reddit.com/r/uBlockOrigin/comments/pyfove/ublock_origin_breaks_corsairs_website_when_using/
@@||googletagmanager.com/gtm.js$script,redirect-rule,domain=corsair.com

! https://www.reddit.com/r/firefox/comments/pz3427/why_gamedevelopercom_former_gamasutra_loads_a/
@@||securepubads.g.doubleclick.net/tag/js/gpt.js$script,redirect-rule,domain=gamedeveloper.com

! https://github.com/uBlockOrigin/uAssets/issues/10146
@@tracking/ninja.js$script,domain=olx.ro,badfilter

! docs.tealium.com blocked by PL
||tealium.com^$badfilter
||tealium.com^$3p

! https://github.com/tofukko/filter/issues/49
@@||pagead2.googlesyndication.com/pagead/js/adsbygoogle.js$script,redirect-rule,domain=heim.jp

! https://github.com/easylist/easylist/issues/9412 cname blocked by PL
@@||777partner.com^$image,media,domain=jetztlive.com

! www.23qb.net cname issue by AG Chinese/EL China
@@||cdn.cloudflare.net^$script,domain=23qb.net

! fix mf-realty.jp top image
@@||googletagmanager.com/gtm.js$script,redirect-rule,domain=mf-realty.jp

! https://www.reddit.com/r/uBlockOrigin/comments/qcw76h/ublocks_blocks_then_page_stops_loading/
myair2.resmed.com##+js(no-xhr-if, cloudflare.com/cdn-cgi/trace)
||cloudflare.com/cdn-cgi/trace$xhr,3p,redirect-rule=noop.txt,domain=~funimation.com|~1bit.space|~1bitspace.com

! https://github.com/uBlockOrigin/uAssets/issues/10285
@@||d2wy8f7a9ursnm.cloudfront.net/*/bugsnag.min.js$script,domain=crust.com.au

! https://www.reddit.com/r/uBlockOrigin/comments/qde4r9/video_player_is_blocked_by_ublock/
||d2r1yp2w7bby2u.cloudfront.net/js/localforage.min.js$script,redirect=noopjs,domain=sonyliv.com

! https://www.reddit.com/r/uBlockOrigin/comments/qeo32a/stooqpl_stooqcom_stopped_working_yesterday/
@@||fundingchoicesmessages.google.com^$script,domain=stooq.com|stooq.pl

! https://github.com/easylist/easylist/issues/2436#issuecomment-946886270
@@*ad2.$image,domain=sophiabushfan.net
@@_advertisment.$image,domain=gorgeouspfeiffer.com
@@_advertisement_$image,domain=jennifer-lawrence.com
@@/advertisements_$image,domain=jessica-biel.at
@@/advertising_$image,domain=timfahlbusch.com
@@/advertisment/*$image,domain=taylorpictures.net
@@/advertisements-$image,domain=jennifer-lawrence.com
@@/ad_campaigns/*$image,domain=alicia-vikander.com
@@/adverts/*$image,domain=emily-blunt.com|isla-fisher.net|islafisher.net|reese-witherspoon.org|reesewitherspoon.org

! https://github.com/uBlockOrigin/uAssets/issues/10348
@@||cloudflare.com/cdn-cgi/trace$xhr,domain=54647.io

! travelerdoor blocked request spam
travelerdoor.com##+js(no-xhr-if, cloudflare.com/cdn-cgi/trace)

! Store selection broken https://www.simon.com/mall/king-of-prussia/stores
@@||googletagmanager.com/gtm.js$script,redirect-rule,domain=simon.com

! https://www.reddit.com/r/uBlockOrigin/comments/qnoufw/pop_ups/hji42s0/
@@||wewon.to^$xhr,media,domain=soap2day.*

! https://github.com/uBlockOrigin/uAssets/issues/10441
pewresearch.org##+js(set, ga, noopFunc)

! https://github.com/uBlockOrigin/uAssets/issues/10444
@@||asset.fwcdn2.com/js/storyblock.js$script,domain=narcity.com

! https://github.com/uBlockOrigin/uAssets/issues/10594
@@||cdn.questionpro.com^$css
