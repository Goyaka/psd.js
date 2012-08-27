class PSDLayerMask
  constructor: (@file, @header, @options) ->
    # Array to hold all of the layers
    @layers = []

    # Does the first alpha channel contain the transparency data?
    @mergedAlpha = false

    # The global layer mask
    @globalMask = {}

    # Additional layer information
    @extras = []

  # Skip over this section and don't parse it
  skip: -> @file.seek @file.readInt()

  parse: ->
    # Read the size of the entire layers and masks section
    maskSize = @file.readInt()
      
    endLoc = @file.tell() + maskSize

    Log.debug "Layer mask size is #{maskSize}"

    # If the mask size is > 0, then parse the section. Otherwise,
    # this section doesn't exist and the whole layers/masks data
    # is 4 bytes (the length we've already read)
    return if maskSize <= 0

    # Size of the layer info section. 4 bytes, rounded up by 2's.
    layerInfoSize = Util.pad2 @file.readInt()

    flag = true
    flag = false if layerInfoSize != 0 
    skip_count = 0
    while flag
      skip_count++
      layerInfoSize = @file.readInt()
      if layerInfoSize != 0 and layerInfoSize < maskSize
        flag = false
    
    if skip_count > 0
      console.log "Skipped #{skip_count} times..."

    # Store the current position in case we need to bail
    # and skip over this section.
    pos = @file.tell()

    # If the layer info size is > 0, then we have some layers
    if layerInfoSize > 0
      # Read the number of layers, 2 bytes.
      @numLayers = @file.readShortInt()

      # If the number of layers is negative, the absolute value is
      # the actual number of layers, and the first alpha channel contains
      # the transparency data for the merged image.
      if @numLayers < 0
        Log.debug "Note: first alpha channel contains transparency data"
        @numLayers = Math.abs @numLayers
        @mergedAlpha = true

      if @numLayers * (18 + 6 * @header.channels) > layerInfoSize
        throw "Unlikely number of #{@numLayers} layers for #{@header['channels']} with #{layerInfoSize} layer info size. Giving up."

      Log.debug "Found #{@numLayers} layer(s)"
      
      for i in [0...@numLayers]
        layer = new PSDLayer @file
        layer.parse(i)
        @layers.push layer

      for layer in @layers
        if layer.isFolder or layer.isHidden
          # Layer contains no image data. Skip ahead.
          @file.seek 8
          continue

        layer.image = new PSDChannelImage(@file, @header, layer)

        if @options.layerImages and ((@options.onlyVisibleLayers and layer.visible) or !@options.onlyVisibleLayers)
          layer.image.parse()
        else
          layer.image.skip()

      # Layers are parsed in reverse order
      @layers.reverse()
      @groupLayers()

    # In case there are filler zeros
    @file.seek pos + layerInfoSize, false

    # Parse the global layer mask
    @parseGlobalMask()
  
    # Temporarily skip the rest of layers & masks section
    @file.seek endLoc, false
    return

    # We have more additional info to parse, especially beacuse this is PS >= 4.0
    @parseExtraInfo(endLoc) if @file.tell() < endLoc

  parseGlobalMask: ->
    length = @file.readInt()
    return if length is 0

    start = @file.tell()
    end = @file.tell() + length

    Log.debug "Global mask length: #{length}"

    # Undocumented
    @globalMask.overlayColorSpace = @file.readShortInt()

    # TODO: parse color space components into actual color.
    @globalMask.colorComponents = []
    for i in [0...4]
      @globalMask.colorComponents.push(@file.readShortInt() >> 8)

    # 0 = transparent, 100 = opaque
    @globalMask.opacity = @file.readShortInt()

    # 0 = color selected; 1 = color protected; 128 = use value per layer
    @globalMask.kind = @file.read(1)[0]

    Log.debug "Global mask:", @globalMask

    # Filler zeros, seek to end.
    @file.seek end, false

  parseExtraInfo: (end) ->
    while @file.tell() < end
      # Temporary
      [
        sig,
        key,
        length
      ] = @file.readf ">4s4sI"

      length = Util.pad2 length

      console.log "Layer extra:", sig, key, length

      @file.seek length

  groupLayers: ->
    groupLayer = null
    for layer in @layers
      if layer.isFolder
        groupLayer = layer
      else if layer.isHidden
        groupLayer = null
      else
        layer.groupLayer = groupLayer

  toJSON: ->
    data =
      mergedAlpha: @mergedAlpha
      globalMask: @globalMask
      extraInfo: @extras
      numLayers: @numLayers
      layers: []

    for layer in @layers
      data.layers.push layer.toJSON()

    data
