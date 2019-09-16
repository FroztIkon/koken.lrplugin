local LrHttp = import 'LrHttp'
local LrMD5 = import 'LrMD5'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrApplication = import "LrApplication"
local myLogger = LrLogger( 'Koken' )
local LrErrors = import "LrErrors"

myLogger:enable( "print" )

JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

KokenUtils = {}
KokenAPI = {}

function KokenUtils.getPublishService(publishSettings)
	local catalog = LrApplication:activeCatalog()
	local publishServices = catalog:getPublishServices( "com.koken.lightroom.export.koken" )
	local publishService
	for _, ps in ipairs( publishServices ) do
		if ps:getPublishSettings().token == publishSettings.token then
			publishService = ps
			break
		end
	end

	return publishService
end

function KokenUtils.getLibrary(publishSettings)
	local publishService = KokenUtils.getPublishService(publishSettings)
	local collections = publishService:getChildCollections()
	return collections[1]
end

function KokenUtils.isInLibrary(publishSettings, photoToCompare)
	local library = KokenUtils.getLibrary(publishSettings)
	for _, photo in ipairs( library:getPublishedPhotos() ) do
		if photo:getRemoteId() == tonumber(photoToCompare) then
			return true
		end
	end
	return false
end

function KokenUtils.getRemoteIdMap(publishSettings)
	local publishService = KokenUtils.getPublishService(publishSettings)
	local remoteId = false
	local map = {}

	LrApplication:activeCatalog():withReadAccessDo( function()

		function search(parent)
			for _, publishedCollectionSet in ipairs( parent:getChildCollectionSets() ) do
				local info = publishedCollectionSet:getCollectionSetInfoSummary()
				search(publishedCollectionSet)
			end

			for _, publishedCollection in ipairs( parent:getChildCollections() ) do
				local info = publishedCollection:getCollectionInfoSummary()
				if not info.isDefaultCollection then
					map[info.localIdentifier] = info.remoteId
				end
			end
		end

		search(publishService)

	end)

	return map
end

function KokenAPI.upload( propertyTable, params, limit )

	-- Adjust limit a bit (10K) to make sure image + data will fit
	limit = limit - 10240

	-- Prepare to upload.
	function fsize (file)
		local current = file:seek()      -- get current position
		local size = file:seek("end")    -- get file size
		file:seek("set", current)        -- restore position
		return size
	end

	function clone (o)
    	local new_o = {}           -- creates a new object
    	local i, v = next(o,nil)   -- get first index of "o" and its value
    	while i do
    		new_o[i] = v             -- store them in new table
    		i, v = next(o,i)         -- get next index and its value
    	end
    	return new_o
   end

	assert( type( params ) == 'table', 'Koken.upload: params must be a table' )

	local url = '/content'
	local mimeChunks = {}

	if params.id then
		local check = KokenAPI.makeGetRequest( propertyTable, '/content/' .. params.id )

		if check and check.id then
			-- myLogger:info('Content exists, PUTing')
			url = url .. '/' .. params.id
			mimeChunks[ #mimeChunks + 1 ] = { name = '_method', value = 'put' }
			params.license = nil
			params.max_download = nil
			params.visibility = nil
		else
			params.id = nil
			-- myLogger:info('Content no longer exists, POSTing')
		end
	end
	-- logger:info( 'uploading photo', params.filePath )

	local filePath = assert( params.filePath )
	params.filePath = nil

	local handle = io.open(filePath, 'rb')
	local size = fsize(handle)

	local chunks = math.ceil(size / limit)

	mimeChunks[ #mimeChunks + 1 ] = { name = 'chunks', value = chunks }

	params.name = LrPathUtils.leafName( filePath )

	for argName, argValue in pairs( params ) do
		if argName ~= 'api_sig' then
			mimeChunks[ #mimeChunks + 1 ] = { name = argName, value = argValue }
		end
	end

	local chunk = 0
	local obj = {}

	while chunk < chunks do
		local bytes = handle:read(limit)
		if not bytes then break end

		local filename = os.tmpname()
		local fh = assert(io.open(filename, 'wb'))
		fh:write(bytes)
		fh:close()

		local _params = clone(mimeChunks)
		_params[ #_params + 1 ] = { name = 'chunk', value = chunk }
		_params[ #_params + 1 ] = { name = 'file', fileName = params.name, filePath = filename, contentType = 'application/octet-stream' }
		obj = KokenAPI.makePostRequest( propertyTable, url, _params )
		chunk = chunk + 1
	end

	if obj then
		return obj
	else
		return false
	end
end

function KokenAPI.processAPIResponse( response, headers )

	local isJson = false

	for i, p in ipairs( headers ) do
		if p.field:lower() == 'content-type' and p.value:lower() == 'application/json' then
			isJson = true
		end
	end

	if isJson then
		return JSON:decode( response )
	else
		return false
	end

end

function KokenAPI.makeGetRequest( propertyTable, url )
	if not propertyTable.protocol then
		propertyTable.protocol = 'http'
	end

	local response, headers = LrHttp.get(propertyTable.protocol .. '://' .. propertyTable.path .. '/api.php?' .. url .. '/token:' .. propertyTable.token);

	return KokenAPI.processAPIResponse( response, headers )
end

function KokenAPI.makePostRequest( propertyTable, url, chunks )
	if not propertyTable.protocol then
		propertyTable.protocol = 'http'
	end
	chunks[ #chunks + 1 ] = { name = 'token', value = propertyTable.token }
	local response, headers = LrHttp.postMultipart(propertyTable.protocol .. '://' .. propertyTable.path .. '/api.php?' .. url, chunks)

	return KokenAPI.processAPIResponse( response, headers )
end

function KokenAPI.removeFromAlbum( propertyTable, params )
	local idMap = KokenUtils.getRemoteIdMap(propertyTable)
	local remoteId = idMap[params.localCollectionId]

	if remoteId then
		local url = '/albums/' .. remoteId .. '/content/' .. table.concat(params.content, ','):gsub('%-album%-%d+', '')
		local chunks = {}
		chunks[ #chunks + 1 ] = { name = '_method', value = 'delete' }
		KokenAPI.makePostRequest(propertyTable, url, chunks)
	end
end

function KokenAPI.deletePhoto( propertyTable, params )
	local library = KokenUtils.getLibrary(propertyTable)
	local delete = false
	local realId = tostring(params.id):gsub('%-album%-%d+', '')
	local albums = KokenAPI.makeGetRequest(propertyTable, '/content/' .. realId .. '/albums')
	local notInAlbums = albums.total == 0

	if params.localCollectionId and library.localIdentifier == params.localCollectionId then
		if notInAlbums then
			delete = true
		end
	elseif not KokenUtils.isInLibrary(propertyTable, realId) and notInAlbums then
		delete = true
	end

	if delete then
		local url = '/content/' .. realId
		local chunks = {}
		chunks[ #chunks + 1 ] = { name = '_method', value = 'delete' }
		KokenAPI.makePostRequest(propertyTable, url, chunks)
	end

end

function KokenAPI.deleteAlbum( propertyTable, params )
	local url = '/albums/' .. params.id
	local chunks = {}
	chunks[ #chunks + 1 ] = { name = '_method', value = 'delete' }
	KokenAPI.makePostRequest(propertyTable, url, chunks)
end

function KokenAPI.addContentToAlbum( propertyTable, params )
	local url = '/albums/' .. params.album .. '/content/' .. params.content
	local chunks = {}
	if params.match_album_visibility then
		chunks[ #chunks + 1 ] = { name = 'match_album_visibility', value = params.match_album_visibility }
	end
	KokenAPI.makePostRequest(propertyTable, url, chunks)
end

function KokenAPI.rootAlbum( propertyTable, params )
	local url = '/albums/' .. params.album
	local album = KokenAPI.makeGetRequest(propertyTable, url, {})
	if album and album.parent then
		local del_url = '/albums/' .. album.parent.id .. '/content/' .. params.album
		local chunks = {}
		chunks[ #chunks + 1 ] = { name = '_method', value = 'delete' }
		KokenAPI.makePostRequest(propertyTable, del_url, chunks)
	end
end

function KokenAPI.createOrUpdateAlbum( propertyTable, params )

	local updateAlbum = false
	local data, response

	if params.albumId then

		data = KokenAPI.makeGetRequest( propertyTable, '/albums/' .. params.albumId )

		if data and data.id then
			updateAlbum = true
		end

	else

		-- TODO: Yeah or neah?
		-- data, response = FlickrAPI.callRestMethod( propertyTable, {
		-- 						method = 'flickr.photosets.getList',
		-- 					} )
		--
		-- local photosetsNode = LrXml.parseXml( response )
		--
		-- local photosetId = traversePhotosetsForTitle( photosetsNode, params.title )
		--
		-- if photosetId then
		-- 	params.photosetId = photosetId
		-- 	needToCreatePhotoset = false
		-- end

	end

	local url = '/albums'

	local chunks = {}
	chunks[ #chunks + 1 ] = { name = 'title', value = params.title }

	if params.albumType then
		chunks[ #chunks + 1 ] = { name = 'album_type', value = params.albumType }
	end

	if updateAlbum then
		url = url .. '/' .. params.albumId
		chunks[ #chunks + 1 ] = { name = '_method', value = 'put' }
	else
		local settings = KokenAPI.makeGetRequest( propertyTable, '/settings')
		local visibility = 'public'

		if settings.uploading_default_album_visibility then
			visibility = settings.uploading_default_album_visibility
		end

		chunks[ #chunks + 1 ] = { name = 'visibility', value = visibility }
	end

	local album = KokenAPI.makePostRequest( propertyTable, url, chunks )

	if not album or album.error then
		local msg = "Saving album failed."
		if not album then
			msg = msg .. " The server did not return an error message. Contact Koken support for more help."
		else
			msg = msg .. " The following error was returned: " .. album.error
		end
		LrErrors.throwUserError(msg)
	else
		return album.id
	end
end
