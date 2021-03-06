_ = require 'lodash'
charm = require 'charm'
stream = require 'stream'

# Wrapper for an output stream (e.g. stdout) that adds an "overlay" in the lower right hand
# corner. Overlay can show a "status" (consistent, purple on white) or a "flash" (goes away after
# a few seconds, white on purple).
#
# Attaching to a non-TTY stream will cause this to pass data through with no modifications.
#
# Not entirely great at what happens when STDOUT lines wrap or the terminal is resized: sometimes
# the overlay will not get erased completely. It seems to work well enough in practice, however.
class OverlayOutputStream extends stream.Writable
  constructor: (@stream, options) ->
    super options
    @charm = charm(@stream)
    @isTTY = @stream.isTTY
    @statusMessage = ''
    @currentOverlayText = ''

    # Needed so that the stream's dimensions can be used for resizing the Docker container
    @columns = @stream.columns
    @rows = @stream.rows

    @lastStreamColumns = @stream.columns

    handleResize = =>
      @writeOverlay()
      @columns = @stream.columns
      @rows = @stream.rows
      @emit 'resize'

    # Handling wrapping is much more reliable with a bit of debounce
    @stream.on 'resize', _.debounce handleResize, 100
    @stream.on 'drain', => @emit 'drain'

  # Sets a message that permanently sits in the lower-right as the stream
  # scrolls by behind it.
  setOverlayStatus: (status) ->
    @statusMessage = status
    if @hasOverlay
      @writeOverlay()

  # Pops a message up (over the status) for a few seconds, then disappears (and
  # status, if any, re-appears).
  flashOverlayMessage: (message) ->
    if @unsetFlashTimeout
      clearTimeout @unsetFlashTimeout

    @unsetFlashTimeout = setTimeout @unsetOverlayFlash.bind(@), 2000
    @flashMessage = message
    @writeOverlay()

  unsetOverlayFlash: ->
    @flashMessage = null
    @writeOverlay()

  clearOverlay: ->
    return unless @hasOverlay

    @charm.push(true)

    # Width from the start of the overlay to the right side of the window. Starts as the length
    # of the text (since it was printed right-aligned) but we add in any new columns that have
    # appeared, or subtract any that have disappeared (our text will be wrapped in that case).
    widthOnLine = @currentOverlayText.length + (@stream.columns - @lastStreamColumns) + 1
    overlayDidWrap = @lastStreamColumns > @stream.columns + 1
    @lastStreamColumns = @stream.columns

    @charm.position(@stream.columns - widthOnLine, @stream.rows)

    # If we wrapped, the start of our text is one above the bottom row, so we have to move up.
    if overlayDidWrap
      @charm.up(1)

    @charm.delete('char', @currentOverlayText.length + 1)

    # We then delete the line that has the wrapped characters on it. 
    if overlayDidWrap
      @charm.down(1)
      @charm.delete('line', 1)

    @charm.pop(true)

    # After the cursor position is restored, we scroll a line to cover up the newly blank one,
    # and have to move the cursor down one line to compensate.
    if overlayDidWrap
      @charm.scroll(-1)
      @charm.down(1)

  writeOverlay: ->
    return unless @isTTY

    @clearOverlay()
    @charm.push(true)

    if @flashMessage
      text = @flashMessage
      @charm.background(13)
      @charm.foreground('white')
    else if @statusMessage
      @charm.foreground(13)
      @charm.background('white')
      text = @statusMessage
    else
      @currentOverlayText = ''
      @charm.pop(true)
      return
    
    @currentOverlayText = if text then " #{text} " else ''

    @charm.position(@stream.columns - @currentOverlayText.length, @stream.rows)
    @charm.write(@currentOverlayText)
    @charm.pop(true)
    @hasOverlay = true

  # Proxy our writes through to the underlying stream, wrapped in
  # making our status disappear and re-appear.
  _write: (chunk, encoding, cb) ->
    # We only redraw if the chunk contains a newline. This is a compromise from redrawing every
    # time, to workaround issues with TTY push and pop. When drawing every time, there's a case
    # where the cursor can be put just outside the terminal window (easy to do with rspec's one-dot-
    # at-a-time output). Pushing that position and popping it ends up bringing the cursor back
    # inside the window, so the line never ends up wrapping.
    #
    # With this solution, we allow writes on one line (and possibly terminal code shenanigans) to
    # overwrite the charm, but preserve the wrapping behavior for one-dot-at-a-time output.
    redraw = chunk.toString().indexOf('\n') isnt -1

    @clearOverlay() if redraw
    ret = @stream.write chunk, encoding, cb
    @writeOverlay() if redraw
    ret

  end: ->
    @clearOverlay()
    super

module.exports = OverlayOutputStream
