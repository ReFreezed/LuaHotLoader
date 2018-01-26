local moduleFolder = ('.'..(...)) :gsub('%.init$', '')
return require((moduleFolder..'.hotLoader'):sub(2))
