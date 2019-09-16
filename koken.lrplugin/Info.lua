return {

	LrSdkVersion = 3.0,
	LrSdkMinimumVersion = 3.0, -- minimum SDK version required by this plug-in

	LrToolkitIdentifier = 'com.koken.lightroom.export.koken',
	LrPluginName = "Koken",
	LrMetadataProvider = 'KokenMetadata.lua',

	LrExportServiceProvider = {
		title = LOC "Koken",
		file = 'KokenExportServiceProvider.lua',
	},

	VERSION = { major=1, minor=2, revision=10, build=0, },

}