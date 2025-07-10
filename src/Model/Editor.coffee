_ = require "underscore"
queryString = require "query-string"
require "whatwg-fetch"
Model = require "./Model"
Util = require "../Util/Util"
Storage = require "../Storage/Storage"
FirebaseAccess = require "../Storage/FirebaseAccess"

module.exports = class Editor
  constructor: ->
    @layout = new Model.Layout()
    @serializer = Model.SerializerWithBuiltIns.getSerializer()

    parsedQuery = queryString.parse(location.search)

    isSelected = (str) => str and str.trim() == '1'

    if isSelected(parsedQuery.showFps)
      @showFps = true
    if isSelected(parsedQuery.experimental)
      @experimental = true
    if isSelected(parsedQuery.fullScreen)
      @layout.setFullScreen(true)
    if isSelected(parsedQuery.viewOnly)
      @layout.setViewOnly(true)
    if isSelected(parsedQuery.editLink)
      @layout.setEditLink(true)
    if parsedQuery.regionOfInterest
      try
        @initialLoadRegionOfInterest = JSON.parse(parsedQuery.regionOfInterest)
      catch e
        @initialLoadError =
          "Error parsing regionOfInterest query parameter: #{e.toString()}"
        return

    if parsedQuery.load
      jsonPromise = @getJsonFromURLPromise(parsedQuery.load)
    else if parsedQuery.loadFirebase
      jsonPromise = @getJsonFromFirebasePromise(parsedQuery.loadFirebase)

    if jsonPromise
      # Remote initial load
      jsonPromise
        .then (json) =>
          @loadJsonStringIntoProject(json)

          if @initialLoadRegionOfInterest
            @project.editingElement.zoomViewMatrixToRegionOfInterest(
              @initialLoadRegionOfInterest,
              window.innerWidth, window.innerHeight)

          @setupRevision()
          Apparatus.refresh()
        .catch (e) =>
          @initialLoadError = e
          Apparatus.refresh()
    else
      @performLocalInitialLoad()

    if @experimental
      # Preload Firebase access so sharing is faster
      @firebaseAccess ?= new FirebaseAccess()

  performLocalInitialLoad: ->
    @loadFromLocalStorage()
    if !@project
      @createNewProject()
    @setupRevision()

  urlForEditMode: ->
    parsedQuery = queryString.parse(location.search)
    for key in ["fullScreen", "viewOnly", "editLink", "regionOfInterest"]
      delete parsedQuery[key]
    return "?" + queryString.stringify(parsedQuery)

  # TODO: get version via build process / ENV variable?
  version: "0.4.1"

  # Given a JSON string, parses it and loads it as the editor's project. This
  # does not modify the revision history, so it is safe for use by undo/redo
  # procedures. However, the caller should make sure to checkpoint and/or
  # refresh Apparatus afterwards if necessary.
  loadJsonStringIntoProject: (jsonString) ->
    json = JSON.parse(jsonString)
    # TODO: If the file format changes, this will need to check the version
    # and convert or fail appropriately.
    if json.type == "Apparatus"
      @project = @serializer.dejsonify(json)
      @project.performIdempotentCompatibilityFixes()

  # Given a JSON string, parses it and merges novel create panel elements into
  # the editor's project. This does not modify the revision history, so the
  # caller should make sure to checkpoint (and/or refresh Apparatus afterwards)
  # if necessary.
  mergeJsonStringIntoProject: (jsonString) ->
    json = JSON.parse(jsonString)
    # TODO: If the file format changes, this will need to check the version
    # and convert or fail appropriately.
    if json.type == "Apparatus"
      otherProject = @serializer.dejsonify(json)
      for createPanelElement in otherProject.createPanelElements
        if createPanelElement not in @project.createPanelElements
          @project.createPanelElements.push(createPanelElement)

  getJsonStringOfProject: ->
    if not @project
      throw "Trying to get JSON string of nonexistent project"

    json = @serializer.jsonify(@project)
    json.type = "Apparatus"
    json.version = @version
    jsonString = JSON.stringify(json)
    return jsonString

  createNewProject: ->
    @project = new Model.Project()


  # ===========================================================================
  # Local Storage
  # ===========================================================================

  localStorageName: "apparatus"

  saveToLocalStorage: ->
    try
      jsonString = @getJsonStringOfProject()
      # Only save if the string isn't too large (leave some room for other data)
      if jsonString.length < 2 * 1024 * 1024  # 2MB limit
        window.localStorage[@localStorageName] = jsonString
      else
        console.warn("Project too large to save to localStorage")
      return jsonString
    catch error
      console.warn("Error saving to localStorage:", error)
      return null

  loadFromLocalStorage: ->
    jsonString = window.localStorage[@localStorageName]
    if jsonString
      @loadJsonStringIntoProject(jsonString)

  resetLocalStorage: ->
    delete window.localStorage[@localStorageName]


  # ===========================================================================
  # File System
  # ===========================================================================

  saveToFile: ->
    jsonString = @getJsonStringOfProject()
    fileName = @project.editingElement.label + ".json"
    Storage.saveFile(jsonString, fileName, "application/json;charset=utf-8")

  loadFromFile: ->
    Storage.loadFile (jsonString) =>
      @loadJsonStringIntoProject(jsonString)
      @checkpoint()
      Apparatus.refresh()  # HACK: calling Apparatus seems funky here.

  mergeFromFile: ->
    Storage.loadFile (jsonString) =>
      @mergeJsonStringIntoProject(jsonString)
      @checkpoint()
      Apparatus.refresh()  # HACK: calling Apparatus seems funky here.


  # ===========================================================================
  # External URL
  # ===========================================================================

  getJsonFromURLPromise: (url) ->
    return fetch(url).then (response) =>
      if not response.ok
        throw "Request for \"#{url}\" failed with code \"#{response.status} #{response.statusText}\""
      return response.text()

  getJsonFromFirebasePromise: (key) ->
    @firebaseAccess ?= new FirebaseAccess()
    @firebaseAccess.loadDrawingPromise(key)
      .then (drawingData) =>
        return drawingData.source

  saveToFirebase: ->
    @firebaseAccess ?= new FirebaseAccess()
    jsonString = @getJsonStringOfProject()
    @firebaseAccess.saveDrawingPromise(jsonString)
      .then (key) ->
        window.prompt(
          'Saved successfully! Copy this link:',
          # TODO: Remove experimental=1 when Firebase access is taken out of
          # experimental mode
          'http://aprt.us/editor/?experimental=1&loadFirebase=' + key)


  # ===========================================================================
  # Symbol Export/Import
  # ===========================================================================

  # Exports the current symbol to a JSON file
  exportCurrentSymbol: ->
    {project} = this
    currentElement = project.editingElement
    
    # Only allow exporting if the current element is in the createPanelElements
    unless currentElement in project.createPanelElements
      alert("Please select a symbol from the left panel to export")
      return
    
    symbolData = @serializer.jsonify(currentElement)
    symbolData.type = "ApparatusSymbol"
    
    jsonString = JSON.stringify(symbolData, null, 2)
    fileName = (currentElement.label || "symbol") + ".json"
    Storage.saveFile(jsonString, fileName, "application/json;charset=utf-8")

  # Exports the current symbol as an SVG file
  exportCurrentSymbolAsSvg: ->
    {project} = this
    currentElement = project.editingElement
    
    # Only allow exporting if the current element is in the createPanelElements
    unless currentElement in project.createPanelElements
      alert("Please select a symbol from the left panel to export")
      return

    try
      # Default DPI
      dpi = 100
      
      # Get root SVG content with default bounds
      viewMatrix = new Util.Matrix(1, 0, 0, -1, 0, 0)  # Just flip Y axis for measurement
      svgContent = currentElement.allGraphics()[0].toSvg({viewMatrix})
      
      # Create temporary SVG to measure bounds
      tempSvg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      tempSvg.innerHTML = svgContent
      document.body.appendChild(tempSvg)
      
      group = tempSvg.querySelector('g')
      bbox = group.getBoundingClientRect()
      document.body.removeChild(tempSvg)
      
      # Add 5px padding (before DPI scaling)
      padding = 5
      
      # Create final SVG with proper viewBox
      viewMatrix = new Util.Matrix(dpi, 0, 0, -dpi, 0, 0)
      
      # Calculate dimensions with padding
      width = bbox.width * dpi + 2 * padding
      height = bbox.height * dpi + 2 * padding
      
      # Adjust viewBox to account for padding
      viewBoxX = bbox.x * dpi - padding
      viewBoxY = bbox.y * dpi - padding
      
      finalSvgContent = currentElement.allGraphics()[0].toSvg({viewMatrix})
      svgString = """
        <svg xmlns="http://www.w3.org/2000/svg" 
             viewBox="#{viewBoxX} #{viewBoxY} #{width} #{height}"
             width="#{width}"
             height="#{height}">
          #{finalSvgContent}
        </svg>
      """
      
      # Save the file
      fileName = (currentElement.label || "symbol") + ".svg"
      Storage.saveFile(svgString, fileName, "image/svg+xml;charset=utf-8")

  # Imports a symbol from a JSON file and adds it to the create panel
  importSymbol: ->
    Storage.loadFile (jsonString) =>
      try
        symbolData = JSON.parse(jsonString)
        if symbolData.type != "ApparatusSymbol"
          throw new Error("Not a valid Apparatus symbol file")
        
        # Deserialize the symbol
        symbol = @serializer.dejsonify(symbolData)
        
        # Add to create panel
        @project.createPanelElements.push(symbol)
        
        # Select the new symbol
        @project.setEditing(symbol)
        
        @checkpoint()
        Apparatus.refresh()
      catch error
        console.error("Error importing symbol:", error)
        alert("Error importing symbol: " + error.message)


  # ===========================================================================
  # Revision History
  # ===========================================================================

  setupRevision: ->
    # @current is a JSON string representing the current state. @undoStack and
    # @redoStack are arrays of such JSON strings.
    @current = @getJsonStringOfProject()
    @undoStack = []
    @redoStack = []
    # Start with a smaller stack size to prevent localStorage issues
    @maxUndoStackSize = 20

  checkpoint: ->
    return if not @undoStack  # revision history hasn't been set up yet

    try
      jsonString = @saveToLocalStorage()
      return if !jsonString || @current == jsonString
      
      @undoStack.push(@current)
      # Reduce max stack size to prevent localStorage overflow
      @maxUndoStackSize = 20
      while @undoStack.length > @maxUndoStackSize
        @undoStack.shift()
      @redoStack = []
      @current = jsonString
    catch error
      console.warn("Could not create checkpoint:", error)
      # Continue without checkpointing rather than crashing

  undo: ->
    return unless @isUndoable()
    @redoStack.push(@current)
    @current = @undoStack.pop()
    @loadJsonStringIntoProject(@current)
    @saveToLocalStorage()

  redo: ->
    return unless @isRedoable()
    @undoStack.push(@current)
    @current = @redoStack.pop()
    @loadJsonStringIntoProject(@current)
    @saveToLocalStorage()

  isUndoable: ->
    return @undoStack.length > 0

  isRedoable: ->
    return @redoStack.length > 0
