class PSDSolidColor
  constructor: (@layer, @length) ->
    @file = @layer.file

  parse: ->
    version = @file.readInt()
    assert version is 16

    descriptor = (new PSDDescriptor(@file)).parse()
    fill_color = Parser.parseColor descriptor.color
    return {"color": fill_color}
    
