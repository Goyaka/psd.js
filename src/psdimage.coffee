# A PSDImage stores parsed image data for images contained within the PSD, and
# for the PSD itself.
class PSDImage
  COMPRESSIONS =
    0: 'Raw'
    1: 'RLE'
    2: 'ZIP'
    3: 'ZIPPrediction'

  channelsInfo: [
    {id: 0},
    {id: 1},
    {id: 2},
    {id: -1}
  ]

  constructor: (@file, @header) ->
    @numPixels = @getImageWidth() * @getImageHeight()

    @length = switch @getImageDepth()
      when 1 then (@getImageWidth() + 7) / 8 * @getImageHeight()
      when 16 then @getImageWidth() * @getImageHeight() * 2
      else @getImageWidth() * @getImageHeight()

    @channelLength = @length # in bytes
    @length *= @getImageChannels()

    @channelData = new Uint8Array(@length)

    @startPos = @file.tell()
    @endPos = @startPos + @length

    @pixelData = []

  parse: ->
    @compression = @parseCompression()

    # ZIP compression isn't implemented yet. Luckily this is pretty rare. Still,
    # it's a TODO.
    Log.debug "Image size: #{@length} (#{@getImageWidth()}x#{@getImageHeight()})"

    if @compression in [2, 3]
      Log.debug "ZIP compression not implemented yet, skipping."
      return @file.seek @endPos, false

    @parseImageData()

  skip: ->
    Log.debug "Skipping image data"
    @file.seek @length

  parseCompression: -> @file.readShortInt()

  parseImageData: ->
    Log.debug "Image compression: id=#{@compression}, name=#{COMPRESSIONS[@compression]}"

    switch @compression
      when 0 then @parseRaw()
      when 1 then @parseRLE()
      when 2, 3 then @parseZip()
      else
        Log.debug "Unknown image compression. Attempting to skip."
        return @file.seek @endPos, false

    @processImageData()

  # Parse the image data as raw pixel values. There is no compression used here.
  parseRaw: (length = @length) ->
    Log.debug "Attempting to parse RAW encoded image..."
    @channelData = []
    @channelData.push @file.read(1)[0] for i in [0...length]

    return true

  # Parse the image with RLE compression. This is the same as the TIFF standard format.
  # Contains the scanline byte lengths first, then the actual encoded image data.
  parseRLE: ->
    Log.debug "Attempting to parse RLE encoded image..."

    # RLE stores the scan line byte counts in the first chunk of data
    @byteCounts = @getByteCounts()

    Log.debug "Read byte counts. Current pos = #{@file.tell()}, Pixels = #{@length}"

    @parseChannelData()

  # Get the height of the image. This varies depending on whether we're parsing layer
  # channel data or not.
  getImageHeight: -> @header.rows
  getImageWidth: -> @header.cols
  getImageChannels: -> @header.channels
  getImageDepth: -> @header.depth

  getByteCounts: ->
    byteCounts = []
    for i in [0...@getImageChannels()]
      for j in [0...@getImageHeight()]
        byteCounts.push @file.readShortInt()

    byteCounts

  parseChannelData: ->
    # And then it stores the compressed image data
    chanPos = 0
    lineIndex = 0

    for i in [0...@getImageChannels()] # i = plane num
      Log.debug "Parsing channel ##{i}, Start = #{@file.tell()}"
      [chanPos, lineIndex] = @decodeRLEChannel(chanPos, lineIndex)

    return true

  decodeRLEChannel: (chanPos, lineIndex) ->
    for j in [0...@getImageHeight()]
      byteCount = @byteCounts[lineIndex++]
      start = @file.tell()

      while @file.tell() < start + byteCount
        [len] = @file.read(1)

        if len < 128
          len++
          data = @file.read len

          # memcpy!
          @channelData[chanPos...chanPos+len] = data
          chanPos += len
        else if len > 128
          len ^= 0xff
          len += 2

          [val] = @file.read(1)
          data = []
          data.push val for z in [0...len]

          @channelData[chanPos...chanPos+len] = data
          chanPos += len

    [chanPos, lineIndex]

  parseZip: (prediction = false) ->
    #stream = inflater.append @file.read(@length)
    #inflater.flush()

    # ZIP decompression not implemented until I can find a PSD that's actually using it
    @file.seek @endPos, false

  # Once we've read the image data, we need to organize it and/or convert the pixel
  # values to RGB so they're easier to work with and can be easily output to either
  # browser or file.
  processImageData: ->
    Log.debug "Processing parsed image data. #{@channelData.length} pixels read."

    switch @header.mode
      when 1 # Greyscale
        @combineGreyscale8Channel() if @getImageDepth() is 8
        @combineGreyscale16Channel() if @getImageDepth() is 16
      when 3 # RGBColor
        @combineRGB8Channel() if @getImageDepth() is 8
        @combineRGB16Channel() if @getImageDepth() is 16
      when 4 #CMKYColor
        @combineCMYK8Channel()

    # Manually delete channel data to free up memory
    delete @channelData

  getAlphaValue: (alpha = 255) ->
    # Layer opacity
    alpha = alpha * (@layer.blendMode.opacity / 255) if @layer?
    alpha

  combineGreyscale8Channel: ->
    if @getImageChannels() is 2
      # Has alpha channel
      for i in [0...@numPixels]
        alpha = @channelData[i]
        grey = @channelData[@channelLength + i]

        @pixelData.push grey, grey, grey, @getAlphaValue(alpha)
    else
      for i in [0...@numPixels]
        @pixelData.push @channelData[i], @channelData[i], @channelData[i], @getAlphaValue()

  combineGreyscale16Channel: ->
    if @getImageChannels() is 2
      # Has alpha channel
      for i in [0...@numPixels]
        alpha = @channelData[i] >> 8
        grey = @channelData[@channelLength + i] >> 8

        @pixelData.push grey, grey, grey, @getAlphaValue(alpha)
    else
      for i in [0...@numPixels]
        @pixelData.push @channelData[i], @channelData[i], @channelData[i], @getAlphaValue()

  combineRGB8Channel: ->
    for i in [0...@numPixels]
      index = 0
      pixel = r: 0, g: 0, b: 0, a: 255

      for chan in @channelsInfo
        switch chan.id
          when -1
            if @getImageChannels() is 4
              pixel.a = @channelData[i + (@channelLength * index)]
            else continue
          when 0 then pixel.r = @channelData[i + (@channelLength * index)]
          when 1 then pixel.g = @channelData[i + (@channelLength * index)]
          when 2 then pixel.b = @channelData[i + (@channelLength * index)]

        index++

      @pixelData.push pixel.r, pixel.g, pixel.b, @getAlphaValue(pixel.a)
      

  combineRGB16Channel: ->
    for i in [0...@numPixels]
      index = 0
      pixel = r: 0, g: 0, b: 0, a: 255

      for chan in @channelsInfo
        switch chan.id
          when -1
            if @getImageChannels() is 4
              pixel.a = @channelData[i + (@channelLength * index)] >> 8
          when 0 then pixel.r = @channelData[i + (@channelLength * index)] >> 8
          when 1 then pixel.g = @channelData[i + (@channelLength * index)] >> 8
          when 2 then pixel.b = @channelData[i + (@channelLength * index)] >> 8

        index++

      @pixelData.push pixel.r, pixel.g, pixel.b, @getAlphaValue(pixel.a)

  combineCMYK8Channel: ->
    for i in [0...@numPixels]
      if @getImageChannels() is 5
        a = @channelData[i]
        c = @channelData[i + @channelLength]
        m = @channelData[i + @channelLength * 2]
        y = @channelData[i + @channelLength * 3]
        k = @channelData[i + @channelLength * 4]
      else
        a = 255
        c = @channelData[i]
        m = @channelData[i + @channelLength]
        y = @channelData[i + @channelLength * 2]
        k = @channelData[i + @channelLength * 3]

      rgb = PSDColor.cmykToRGB(255 - c, 255 - m, 255 - y, 255 - k)

      @pixelData.push rgb.r, rgb.g, rgb.b, @getAlphaValue(a)

      
  # Normally, the pixel data is stored in planar order, meaning all the red
  # values come first, then the green, then the blue. In the HTML canvas, the
  # pixel color values are grouped by pixel such that the values alternate
  # between R, G, B, A over and over.
  #
  # This will return the pixels in the same format that is used by the HTML 
  # canvas. It is a 1D array that consists of a single pixel's color values 
  # expressed from 0 to 255 in chunks of 4. Each chunk consists of red, 
  # green, blue, and alpha values, respectively.
  #
  # This means a pure-red single pixel is expressed as: `[255, 0, 0, 255]`
  toCanvasPixels: -> @pixelData

  toFile: (filename, cb) ->
    png = @getPng()
    png.encode (image) -> fs.writeFile filename, image, cb

  toFileSync: (filename) ->
    png = @getPng()
    image = png.encodeSync()
    fs.writeFileSync filename, image

  getPng: ->
    try
      {Png} = require 'png'
    catch e
      throw "Exporting PSDs to file requires the node-png library"

    buffer = new Buffer @toCanvasPixels().length
    pixelData = @toCanvasPixels()

    for i in [0...pixelData.length] by 4
      buffer[i] = pixelData[i]
      buffer[i+1] = pixelData[i+1]
      buffer[i+2] = pixelData[i+2]
      buffer[i+3] = 255 - pixelData[i+3] # Why is this inverted?

    new Png buffer, @getImageWidth(), @getImageHeight(), 'rgba'

  toCanvas: (canvas, width = null, height = null) ->
    if width is null and height is null
      canvas.width = @getImageWidth()
      canvas.height = @getImageHeight()

    context = canvas.getContext('2d')
    imageData = context.getImageData 0, 0, canvas.width, canvas.height
    pixelData = imageData.data

    pixelData[i] = pxl for pxl, i in @toCanvasPixels()

    context.putImageData imageData, 0, 0

  toImage: ->
    canvas = document.createElement 'canvas'
    @toCanvas canvas
    canvas.toDataURL "image/png"
