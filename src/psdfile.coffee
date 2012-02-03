# Simulation and abstraction of a disk-based file.
# Provides methods to read the raw binary file data, which
# is stored in a variable instead of read from disk.
class PSDFile
  constructor: (@data) ->
    @pos = 0

  tell: -> @pos
  read: (bytes) -> (@data[@pos++] for i in [0...bytes])
  seek: (amount, rel = true) ->
    if rel then @pos += amount else @pos = amount

  readUInt32: ->
    b1 = @data[@pos++] << 24
    b2 = @data[@pos++] << 16
    b3 = @data[@pos++] << 8
    b4 = @data[@pos++]
    b1 | b2 | b3 | b4
      
  readUInt16: ->
    b1 = @data[@pos++] << 8
    b2 = @data[@pos++]
    b1 | b2

  #
  # Helper functions so we don't have to remember the unpack
  # format codes.
  #
  
  # 4 bytes
  readInt: -> @readf(">i")[0]
  readUInt: -> @readf(">I")[0]

  # 2 bytes
  readShortInt: -> @readf(">h")[0]
  readShortUInt: -> @readf(">H")[0]

  # 4 bytes
  readLongInt: -> @readf(">l")[0]
  readLongUInt: -> @readf(">L")[0]

  # 8 bytes
  readDouble: -> @readf(">d")[0]

  # 1 byte
  readBoolean: -> @read(1)[0] isnt 0

  readUnicodeString: ->
    str = ""
    strlen = @readUInt()
    for i in [0...strlen]
      charCode = @readShortUInt()
      str += chr(Util.i16(charCode)) if charCode > 0

    str

  readDescriptorStructure: ->
    name = @readUnicodeString()
    classID = @readLengthWithString()
    items = @readUInt()

    descriptors = {}
    for i in [0...items]
      key = @readLengthWithString().trim()
      descriptors[key] = @readOsType()

    descriptors

  readString: (length) -> @readf ">#{length}s"

  # Used for reading Pascal strings
  readLengthWithString: (defaultLen = 4) ->
    length = @readUInt()
    if length is 0
      [str] = @readf ">#{defaultLen}s"
    else
      [str] = @readf ">#{length}s"

    str

  readOsType: ->
    osType = @readString(4)
    value = null
    switch osType
      when "TEXT" then value = @readUnicodeString()
      when "enum", "Objc", "GlbO"
        value =
          typeID: @readLengthWithString()
          enum: @readLengthWithString()
      when "VlLs"
        listSize = @readUInt()
        value = []
        value.push(@readOsType()) for i in [0...listSize]
      when "doub" then value = @readDouble()
      when "UntF"
        value =
          type: @readString(4)
          value: @readDouble()
      when "long" then value = @readUInt()
      when "bool" then value = @readBoolean()
      when "alis"
        length = @readUInt()
        value = @readString(length)
      when "obj"
        num = @readUInt()
        for i in [0...num]
          type = @readString(4)
          switch type
            when "prop"
              value =
                name: @readUnicodeString()
                classID: @readLengthWithString()
                keyID: @readLengthWithString()
            when "Clss"
              value =
                name: @readUnicodeString()
                classID: @readLengthWithString()
            when "Enmr"
              value =
                name: @readUnicodeString()
                classID: @readLengthWithString()
                typeID: @readLengthWithString()
                enum: @readLengthWithString()
            when "rele"
              value =
                name: @readUnicodeString()
                classID: @readLengthWithString()
                offsetValue: @readUInt()
            when "Idnt", "indx", "name" then value = null
      when "tdta"
        # Skip this
        length = @readUInt()
        @seek length

    {type: osType, value: value}

  readBytesList: (size) ->
    bytesRead = @read size
    result = []
    result.push ord(b) for b in bytesRead
    result
  
  readf: (format) -> jspack.Unpack format, @read(jspack.CalcLength(format))

  skipBlock: (desc) ->
    [n] = @readf('>L')
    @seek(n) if n # relative

    Log.debug "Skipped #{desc} with #{n} bytes"