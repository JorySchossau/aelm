--warnings:off
--hints:off
switch("define","cputype=x86_64")

--define:ssl

# required for stand-alone SSL
#--threads:on
#--dynlibOverride:ssl
#--passL:"lib/libssl.a"
#--passL:"lib/libcrypto.a"

#--cc:clang
#--clang.exe:"nim/bin/zigcc.sh"
#--clang.linkerexe:"nim/bin/zigcc.sh"
