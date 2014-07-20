
fs       = require 'fs'
pathUtil = require 'path'
mkdirp   = require 'mkdirp'
binSrch  = require 'binarysearch'

{diff_match_patch; DIFF_DELETE, DIFF_INSERT, DIFF_EQUAL} =
    require '../vendor/diff_match_patch.js'
DIFF_BASE = 2

maxTextCacheSize = 1e6

curPath       = ''
index         = []
textCache     = {}
textCacheSize = 0

readUInt48 = (buf, ofs) ->
  ms16 = buf.readUInt16BE ofs
  ls32 = buf.readUInt32BE ofs+2
  ms16 * 0x100000000 + ls32

readHdr = (buf, pos) ->
  time       = buf.readUInt48 pos
  fileBegPos = buf.readUInt48 pos + 6
  fileEndPos = buf.readUInt48 pos + 12
  {time, fileBegPos, fileEndPos}

pruneTextCache = ->
  if textCacheSize < maxTextCacheSize then return

  now = Date.now()
  dates = []
  for date, text of textCache
    if +date < now - 60 * 1000
      textCacheSize -= text.length
      delete textCache[date]
      continue
    dates.push [date, text.length]
  if textCacheSize < maxTextCacheSize then return

  dates.sort()
  for dateMin in dates
    while textCacheSize > maxTextCacheSize
      textCacheSize -= dateMin[1]
      delete textCache[date]
  null

timeToStr = (time) ->
  str = '' + time
  while str.length < 15 then str = '0' + str
  str

getText = (timeTgt) ->
  if (text = textCache[timeToStr timeTgt]) then return text
  if index.length is 0 or index[0] > timeTgt then return ''

  idx = binSrch.closest index, timeTgt, (val, find) -> val.time - find
  if timeTgt < index[idx].time then idx--
  time = index[idx].time
  if (text = textCache[timeToStr time]) then return text

  fd = fs.openSync pathUtil.join(curPath, 'data'), 'r'
  diffs = []
  cachecount = -1
  for i in [idx..0] by -1
    {time, fileBegPos, fileEndPos} = index[i]
    if (baseText = textCache[timeToStr time])
      cachecount = 0
      break
    diffLen = fileEndPos - fileBegPos
    diffBuf = new Buffer diffLen
    fs.readSync fd, diffBuf, 0, diffLen, fileBegPos
    if diffBuf.readInt8(18, yes) is DIFF_BASE
      baseText = diffBuf.toString 25
      break
    diffs.unshift {time, diffBuf}
  fs.closeSync fd

  curText = baseText
  for diff in diffs
    {time, diffBuf} = diff
    diffPos = 18
    curTextPos = 0
    nextText = ''
    while diffPos < diffBuf.length - 6
      diffType = diffBuf.readInt8 diffPos, yes
      dataLen  = readUInt48(diffBuf, diffPos + 1) - 7
      diffPos += 7
      switch diffType
        when DIFF_EQUAL
          nextText   += curText[curTextPos...(curTextPos+dataLen)]
          curTextPos += dataLen
        when DIFF_DELETE
          curTextPos += dataLen
        when DIFF_INSERT
          nextText += diffBuf.toString diffPos, diffPos + dataLen
          diffPos  += dataLen
    curText = nextText
    if ++cachecount % 5 is 0
      textCache[timeToStr time] = curText
      pruneTextCache()

  curText

loadPath = (path) ->
  if path isnt curPath
    curPath = path
    textCache = {}
    textCacheSize = 0
    if path then
      indexPath = pathUtil.join path, 'index'
      try
        indexBuf = fs.readFileSync indexPath
      catch e
        indexBuf = new Buffer()
        mkdirp.sync pathUtil.dirname path
        fs.closeSync fs.openSync indexPath, 'a'
      pos = 0
      index = []
      while pos < indexBuf.length
        index.push readHdr indexBuf, pos
        pos += 18

      dataPath = pathUtil.join path, 'data'
      try
        fs.statSync dataPath
      catch e
        mkdirp.sync pathUtil.dirname path
        fs.closeSync fs.openSync dataPath, 'a'

load = exports

load.text = (path, time = Number.MAXINT) -> loadPath path; getText time
