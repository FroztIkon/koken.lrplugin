	-- Lightroom SDK
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrView = import 'LrView'
local LrLogger = import 'LrLogger'
local LrHttp = import 'LrHttp'
local LrMD5 = import 'LrMD5'
local LrFunctionContext = import 'LrFunctionContext'
local LrPath = import 'LrPathUtils'
local LrApplication = import 'LrApplication'
local LrErrors = import "LrErrors"
local LrTasks = import "LrTasks"

local myLogger = LrLogger( 'Koken' )
myLogger:enable( "print" )

JSON = (assert(loadfile(LrPath.child(_PLUGIN.path, "JSON.lua"))))()

	-- Common shortcuts
local bind = LrView.bind
local share = LrView.share

require 'KokenAPI'

local exportServiceProvider = {}
local publishServiceProvider = {}

exportServiceProvider.supportsIncrementalPublish = true

exportServiceProvider.hideSections = { 'exportLocation' }

exportServiceProvider.allowFileFormats = { 'JPEG' }

exportServiceProvider.allowColorSpaces = { 'sRGB' }

exportServiceProvider.hidePrintResolution = true

exportServiceProvider.canExportVideo = true

exportServiceProvider.small_icon = 'icon.png'

exportServiceProvider.publish_fallbackNameBinding = 'user'

exportServiceProvider.titleForPublishedCollection = "Album"

exportServiceProvider.titleForPublishedSmartCollection = "Smart Album"

exportServiceProvider.titleForPublishedCollectionSet = "Album Set"

exportServiceProvider.exportPresetFields = {
	{ key = 'user', default = "" },
	{ key = 'path', default = "" },
	{ key = 'token', default = "" },
	{ key = 'secret', default = "" }
}

function exportServiceProvider.getCollectionBehaviorInfo( publishSettings )

	return {
		defaultCollectionName = "Library",
		defaultCollectionCanBeDeleted = false,
		canAddCollection = true,
		maxCollectionSetDepth = 5,
	}

end

function exportServiceProvider.startDialog( propertyTable )

	-- Clear login if it's a new connection.

	if (not propertyTable.LR_editingExistingPublishConnection and propertyTable.LR_isExportForPublish) or propertyTable.user == '' then
		propertyTable.user = nil
	end

	if propertyTable.user == nil then
		propertyTable.LR_removeLocationMetadata = false
		propertyTable.LR_jpeg_quality = 1
		propertyTable.auth_token = nil
		propertyTable.auth_secret = nil
		propertyTable.path = nil
		propertyTable.accountStatus = 'Not logged in'
		propertyTable.loginButtonTitle = 'Log in'
		propertyTable.loginButtonEnabled = true
		propertyTable.path = ''
	end

	checkAuthStatus( propertyTable )
end

function exportServiceProvider.sectionsForTopOfDialog( f, propertyTable )

	return {

		{
			title = "Koken Account",

			synopsis = bind 'accountStatus',

			f:row {
				spacing = f:control_spacing(),

				f:static_text {
					title = bind 'accountStatus',
					alignment = 'right',
					fill_horizontal = 1,
				},

				f:push_button {
					title = bind 'loginButtonTitle',
					enabled = bind 'loginButtonEnabled',
					action = function()
						login( propertyTable )
					end,
				},

			},
		},
	}

end

function checkAuthStatus( propertyTable )
	if propertyTable.user == nil then
		propertyTable.accountStatus = 'Not logged in'
		propertyTable.loginButtonTitle = 'Log in'
		propertyTable.loginButtonEnabled = true
	else
		propertyTable.accountStatus = 'Logged in as ' .. propertyTable.user
		propertyTable.loginButtonTitle = 'Update'
		propertyTable.loginButtonEnabled = true
	end
end

function login( propertyTable )

	LrFunctionContext.postAsyncTaskWithContext( 'Koken login',
	function( context )
		propertyTable.accountStatus = "Authenticating..."
		propertyTable.loginButtonEnabled = false

		LrDialogs.attachErrorDialogToFunctionContext( context )

		context:addCleanupHandler( function()

			checkAuthStatus( propertyTable )

		end )

		local f = LrView.osFactory() --obtain a view factory

		local contents = f:column {
			spacing = f:control_spacing(),
			fill = 1,

			f:static_text {
				title = "Lightroom needs your permission to upload content to Koken",
				fill_horizontal = 1,
				width_in_chars = 40,
				height_in_lines = 1,
				font = '<system/bold>'
			},

			f:static_text {
				title = "Enter your Koken API path (see Setting/Applications in Koken) then click Authorize. You will then sign-in to Koken through your web browser to grant access.",
				fill_horizontal = 1,
				width_in_chars = 40,
				height_in_lines = 2,
				size = 'small',
			},

			f:row {	-- create UI elements
				spacing = f:label_spacing(),
				margin_vertical = 5,
				bind_to_object = propertyTable, -- default bound table is the one we made
				f:static_text {
					title = "Koken API path:",
					alignment = 'right',
				},
				f:edit_field {
					fill_horizonal = 1,
					width_in_chars = 30,
					value = LrView.bind( 'path' ),-- edit field shows settings value
				},
			},
		}

		local result = LrDialogs.presentModalDialog( -- invoke a dialog box
			{
				title = "Authorize",
				contents = contents,
				actionVerb = 'Authorize',
			}
		)

		if result == 'cancel' then
			return
		end

		math.randomseed( os.time() )
		local nonce = LrMD5.digest( tostring(math.random(1000000)) )
		local proto = 'http://'

		if propertyTable.path:find('https://') == 1 then
			proto = 'https://'
		end

		propertyTable.path = propertyTable.path:gsub('^https?:\/\/', '')
		propertyTable.path = propertyTable.path:gsub('\/$', '')

		local authPath = proto .. propertyTable.path .. '/admin/#/settings/applications'
		LrHttp.openUrlInBrowser( authPath .. '/name:Koken%20Lightroom%20Publish%20Service/role:read-write/callback:oob/nonce:' .. nonce )

		propertyTable.accountStatus = "Waiting for response from Koken..."

		local waitForAuthDialogResult = LrDialogs.confirm(
			"Return to this window once you've authorized Lightroom in Koken",
			"Once you've granted permission for Lightroom (in your web browser), click the Done button below.",
			"OK, I'm done",
			"Cancel" )

		if waitForAuthDialogResult == 'cancel' then
			return
		end

		local tokenResponse = LrHttp.get( proto .. propertyTable.path .. '/api.php?/auth/token/' .. nonce)
		local response = JSON:decode(tokenResponse);
		if response then
			if response.error then
				LrErrors.throwUserError("Unable to authenticate. Koken returned the following error: " .. response.error)
			else
				propertyTable.user = response.user
				propertyTable.token = response.token
				propertyTable.secret = response.secret
				if response.host then
					propertyTable.path = string.gsub( propertyTable.path, "([^/]+)/(.*)", response.host .. "/%2" )
				end
				if response.ssl then
					propertyTable.protocol = 'https'
				else
					propertyTable.protocol = 'http'
				end
			end
		end

	end )
end

function exportServiceProvider.reparentPublishedCollection( publishSettings, info )
	local catalog = LrApplication.activeCatalog()
	local child

	if info.remoteId then
		child = info.remoteId
	else
		if info.publishedCollection:type() == 'LrPublishedCollection' then
			local albumType = 0
		else
			local albumType = 2
		end

		child = KokenAPI.createOrUpdateAlbum( publishSettings, { title = info.name, albumType = albumType });

		catalog:withWriteAccessDo( 'Saving remote id...', function( context )
			info.publishedCollection:setRemoteId( child )
		end )
	end

	if #info.parents > 0 then
		local parent = info.parents[#info.parents].remoteCollectionId

		KokenAPI.addContentToAlbum( publishSettings, {
			album = parent,
			content = child,
		} )
	else
		KokenAPI.rootAlbum( publishSettings, {
			album = child
		} )
	end

end

function exportServiceProvider.updateCollectionSetSettings( publishSettings, info )
	remoteId = info.publishedCollection:getRemoteId()
	-- Only handle a create here. Otherwise, renamePublishedCollection will take care of it.
	if not remoteId then
		id = KokenAPI.createOrUpdateAlbum( publishSettings, { albumId = remoteId, title = info.name, albumType = 2 });

		if #info.parents > 0 then
			KokenAPI.addContentToAlbum( publishSettings, {
				album = info.parents[#info.parents].remoteCollectionId,
				content = id,
			} )
		end

		catalog = LrApplication.activeCatalog()
		catalog:withWriteAccessDo( 'Saving remote id...', function( context )
			info.publishedCollection:setRemoteId( id )
		end )
	end
end

function exportServiceProvider.metadataThatTriggersRepublish( publishSettings )

	return {

		default = true
	}

end

function exportServiceProvider.deletePublishedCollection( publishSettings, info )

	LrFunctionContext.callWithContext( 'exportServiceProvider.deletePublishedCollection', function( context )

		local progressScope = LrDialogs.showModalProgressDialog {
							title = "Deleting " .. info.name,
							functionContext = context }

		if info and info.remoteId then

			KokenAPI.deleteAlbum( publishSettings, {
								id = info.remoteId
							} )

		end

		if info.publishedCollection:type() == 'LrPublishedCollection' then

			local photos = info.publishedCollection:getPublishedPhotos()

			for i, p in ipairs( photos ) do
				local contentId = p:getRemoteId();
				progressScope:setPortionComplete( i - 1, #photos )
				KokenAPI.deletePhoto( publishSettings, { id = contentId, localCollectionId = info.remoteId } )
			end

		end

	end )

end

function exportServiceProvider.deletePhotosFromPublishedCollection( publishSettings, arrayOfPhotoIds, deletedCallback, localId )

	KokenAPI.removeFromAlbum( publishSettings, {
		content = arrayOfPhotoIds,
		localCollectionId = localId,
	} )

	for i, photoId in ipairs( arrayOfPhotoIds ) do
		KokenAPI.deletePhoto( publishSettings, {
			id = photoId,
			localCollectionId = localId
		} )
		deletedCallback( photoId )
	end

end

function exportServiceProvider.renamePublishedCollection( publishSettings, info )
	if info.remoteId then

		KokenAPI.createOrUpdateAlbum( publishSettings, {
			albumId = info.remoteId,
			title = info.name,
		} )

	end

end

function exportServiceProvider.processRenderedPhotos( functionContext, exportContext )

	local exportSession = exportContext.exportSession

	local isPublish = exportContext.propertyTable.LR_isExportForPublish

	-- Make a local reference to the export parameters.

	local exportSettings = assert( exportContext.propertyTable )

	-- Get the # of photos.

	local nPhotos = exportSession:countRenditions()

	-- Set progress title.

	local progressScope = exportContext:configureProgress {
						title = nPhotos > 1
									and "Publishing " .. nPhotos .. " photos to Koken"
									or "Publishing 1 photo to Koken",
					}

	-- Save off uploaded photo IDs so we can take user to those photos later.

	local uploadedPhotoIds = {}

	local publishedCollectionInfo
	local isDefaultCollection
	local albumId
	local albumUrl

	local system = KokenAPI.makeGetRequest( exportSettings, '/system')

	if not system or system.error then
		if not system then
			LrErrors.throwUserError( "Unable to connect to your Koken installation. Make sure the installation is properly running and no firewalls or security software is blocking Lightroom's connection to Koken." )
		else
			LrErrors.throwUserError( "Unable to connect to your Koken installation. Koken returned the following error: " .. system.error )
		end
	end

	local settings = KokenAPI.makeGetRequest( exportSettings, '/settings')

	if not settings or settings.error then
		if not settings then
			LrErrors.throwUserError( "Unable to connect to your Koken installation. Make sure the installation is properly running and no firewalls or security software is blocking Lightroom's connection to Koken." )
		else
			LrErrors.throwUserError( "Unable to connect to your Koken installation. Koken returned the following error: " .. settings.error )
		end
	end

	if isPublish then
		publishedCollectionInfo = exportContext.publishedCollectionInfo

		isDefaultCollection = publishedCollectionInfo.isDefaultCollection

		-- Look for a photoset id for this collection.

		albumId = publishedCollectionInfo.remoteId

		if albumId then
			local check = KokenAPI.makeGetRequest( exportSettings, '/albums/' .. albumId )

			if not check or check.error then
				albumId = false
				-- myLogger:info('Album no longer exists, recreating')
			end
		end

		if not albumId and not isDefaultCollection then

			-- myLogger:info('Creating album: ', publishedCollectionInfo.name)
			albumId = KokenAPI.createOrUpdateAlbum( exportSettings, {
				title = publishedCollectionInfo.name
			} );

			if #publishedCollectionInfo.parents > 0 then
				local parent = publishedCollectionInfo.parents[#publishedCollectionInfo.parents].remoteCollectionId

				KokenAPI.addContentToAlbum( exportSettings, {
					album = parent,
					content = albumId
				} )
			end

		end

		if albumId then
			albumUrl = 'http://' .. exportSettings.path .. '/admin/#/library/albums/' .. albumId .. '/content'
		elseif isDefaultCollection then
			albumUrl = 'http://' .. exportSettings.path .. '/admin/#/library'
		end

		publishedCollectionInfo.remoteId = albumId

		if ( not isDefaultCollection ) then
			exportSession:recordRemoteCollectionId( albumId )
		end

		exportSession:recordRemoteCollectionUrl( albumUrl )

	end

	local upload_session_start = os.time()

	-- myLogger:info('INIT')

	for i, rendition in exportContext:renditions { stopIfCanceled = true } do

		-- myLogger:info('Rendition N: ', i)

		-- Update progress scope.

		progressScope:setPortionComplete( ( i - 1 ) / nPhotos )

		-- Get next photo.

		local photo = rendition.photo

		if not rendition.wasSkipped then

			local success, pathOrMessage = rendition:waitForRender()

			-- Update progress scope again once we've got rendered photo.

			progressScope:setPortionComplete( ( i - 0.5 ) / nPhotos )

			-- Check for cancellation again after photo has been rendered.

			if progressScope:isCanceled() then break end

			if success then

				-- Build up common metadata for this photo.

				local title = photo:getFormattedMetadata( 'title' )
				local caption = photo:getFormattedMetadata( 'caption' )
				local keywordTags = false

				if (exportSettings.LR_embeddedMetadataOption == 'all') then
					keywordTags = photo:getFormattedMetadata( 'keywordTagsForExport' )
				end

				local tags = {}

				if keywordTags then

					local keywordIter = string.gfind( keywordTags, "[^,]+" )

					for keyword in keywordIter do

						if string.sub( keyword, 1, 1 ) == ' ' then
							keyword = string.sub( keyword, 2, -1 )
						end

						tags[ #tags + 1 ] = keyword

					end

				end

				function checker()
					local val = tonumber(photo:getPropertyForPlugin( _PLUGIN, 'kokenIsUploading'))
					return val and os.time() - val < 600
				end

				while checker() do
					-- myLogger:info('KOKEN Lr: Another copy of this photo is already uploading...waiting for it to complete.')
					LrTasks.sleep(0.5)
				end

				-- myLogger:info('Starting')

				photo.catalog:withPrivateWriteAccessDo( function()
					photo:setPropertyForPlugin( _PLUGIN, "kokenIsUploading", os.time() )
				end, { timeout = 1 })

				-- publishedPhotoId only works if it was already published within this collection
				-- Rely on kokenContentId below to see if it already exists elsewhere
				local contentId = rendition.publishedPhotoId

				if contentId then
					if type(contentId) == 'string' then
						contentId = contentId:gsub('%-album%-%d+', '')
					end
				else
					local contentIds = photo:getPropertyForPlugin( _PLUGIN, "kokenContentId" )
					if contentIds and type(contentIds) == 'string' then
						local matches = contentIds:match(',' .. exportSettings.token .. '%-(%d+),')
						if matches then
							contentId = matches
						end
					end
				end

				local _upload_time

				if contentId then
					_upload_time = nil
					-- myLogger:info('Found existing content ID: ' .. contentId)
				else
					_upload_time = upload_session_start
				end

				local contentObj = KokenAPI.upload( exportSettings, {
										id = contentId,
										filePath = pathOrMessage,
										title = title or '',
										caption = caption,
										tags = table.concat( tags, ',' ),
										visibility = settings.uploading_default_visibility,
										max_download = settings.uploading_default_max_download_size,
										license = settings.uploading_default_license,
										upload_session_start = _upload_time
									}, system.upload_limit )

				LrFileUtils.delete( pathOrMessage )

				photo.catalog:withPrivateWriteAccessDo( function()
					photo:setPropertyForPlugin( _PLUGIN, "kokenIsUploading", 'no' )
				end, { timeout=1 } )

				if not contentObj or contentObj.error then
					local msg = "Upload to Koken failed."
					if not contentObj then
						msg = msg .. " The server did not return an error message. Contact Koken support for more help."
					else
						msg = msg .. " The following error was returned: " .. contentObj.error
					end
					LrErrors.throwUserError(msg)
				end

				photo.catalog:withPrivateWriteAccessDo( function()
					local matcher = ',' .. exportSettings.token .. '%-(%d+),'
					local key = ',' .. exportSettings.token .. '-' .. contentObj.id .. ','
					local contentIds = photo:getPropertyForPlugin( _PLUGIN, "kokenContentId" )
					if contentIds and type(contentIds) == 'string' then
						contentIds = contentIds:gsub(matcher, ''):gsub(',$', '')
					else
						contentIds = ''
					end
					contentIds = contentIds .. key
					photo:setPropertyForPlugin( _PLUGIN, "kokenContentId", contentIds )
				end, { timeout=5 } )

				if isPublish then
					-- Remember this in the list of photos we uploaded.

					uploadedPhotoIds[ #uploadedPhotoIds + 1 ] = contentObj.id

					local publishUrl
					local publishId = contentObj.id

					if isDefaultCollection then

						publishUrl = contentObj.url

					elseif publishedCollectionInfo.remoteId then

						local match_album_visibility = 1
						if contentId then
							match_album_visibility = 0
						end

						KokenAPI.addContentToAlbum( exportSettings, {
							album = publishedCollectionInfo.remoteId,
							content = contentObj.id,
							match_album_visibility = match_album_visibility
						} )

						local albumContent = KokenAPI.makeGetRequest(exportSettings, '/content/' .. contentObj.id .. '/context:' .. publishedCollectionInfo.remoteId)
						publishUrl = albumContent.url
						publishId = publishId .. '-album-' .. publishedCollectionInfo.remoteId
					end

					-- myLogger:info('Published Photo ID: ' .. publishId)
					-- myLogger:info('Published Photo URL: ' .. publishUrl)
					rendition:recordPublishedPhotoId( publishId )
					rendition:recordPublishedPhotoUrl( publishUrl )
				end

			end

		end

	end

	progressScope:done()

end

return exportServiceProvider
