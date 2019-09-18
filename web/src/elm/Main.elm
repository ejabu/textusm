module Main exposing (init, main, view)

import Api.Diagram as DiagramApi
import Api.Export
import Api.UrlShorter as UrlShorterApi
import Basics exposing (max)
import Browser
import Browser.Dom as Dom
import Browser.Events exposing (Visibility(..))
import Browser.Navigation as Nav
import Components.Diagram as Diagram
import Constants
import File exposing (name)
import File.Download as Download
import File.Select as Select
import Html exposing (Html, div, main_)
import Html.Attributes exposing (class, style)
import Html.Events exposing (onClick)
import Html.Lazy exposing (lazy, lazy2, lazy3, lazy4, lazy5, lazy6, lazy7, lazy8)
import Json.Decode as D
import List.Extra as ListEx
import Maybe.Extra as MaybeEx exposing (isJust, isNothing)
import Models.Diagram as DiagramModel
import Models.DiagramItem exposing (DiagramItem, DiagramUser)
import Models.DiagramType as DiagramType exposing (DiagramType)
import Models.Model as Model exposing (FileType(..), Model, Msg(..), Notification(..), Settings, ShareUrl(..), Window)
import Models.User as UserModel exposing (User)
import Parser
import Route exposing (Route(..), toRoute)
import Settings exposing (settingsDecoder)
import String
import Subscriptions exposing (..)
import Task
import Time exposing (Zone)
import Url as Url exposing (percentDecode)
import Utils
import Views.DiagramList as DiagramList
import Views.Editor as Editor
import Views.Empty as Empty
import Views.Header as Header
import Views.Icon as Icon
import Views.Logo as Logo
import Views.Menu as Menu
import Views.Notification as Notification
import Views.ProgressBar as ProgressBar
import Views.ShareDialog as ShareDialog
import Views.SplitWindow as SplitWindow
import Views.SwitchWindow as SwitchWindow


init : ( String, Settings ) -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        ( apiRoot, settings ) =
            flags

        ( model, cmds ) =
            changeRouteTo (toRoute url)
                { id = settings.diagramId
                , diagramModel = Diagram.init settings.storyMap
                , text = settings.text |> Maybe.withDefault ""
                , openMenu = Nothing
                , title = settings.title
                , isEditTitle = False
                , window =
                    { position = settings.position |> Maybe.withDefault 0
                    , moveStart = False
                    , moveX = 0
                    , fullscreen = False
                    }
                , share = Nothing
                , settings = settings
                , notification = Nothing
                , url = url
                , key = key
                , tabIndex = 1
                , progress = True
                , apiRoot = apiRoot
                , diagrams = Nothing
                , filterDiagramList = Nothing
                , timezone = Nothing
                , loginUser = Nothing
                , isOnline = True
                , searchQuery = Nothing
                , inviteMailAddress = Nothing
                , currentDiagram = Nothing
                , embed = Nothing
                }
    in
    ( model
    , Cmd.batch
        [ Task.perform GotTimeZone Time.here
        , cmds
        ]
    )


view : Model -> Html Msg
view model =
    main_
        [ style "position" "relative"
        , style "width" "100vw"
        , style "height" "100vh"
        , onClick CloseMenu
        ]
        [ lazy7 Header.view model.diagramModel.width model.loginUser (toRoute model.url) model.title model.isEditTitle model.window.fullscreen model.openMenu
        , lazy networkStatus model.isOnline
        , lazy showNotification model.notification
        , lazy showProgressbar model.progress
        , lazy7 sharingDialogView
            (toRoute model.url)
            model.loginUser
            model.embed
            model.share
            model.inviteMailAddress
            (model.currentDiagram
                |> Maybe.map (\x -> x.ownerId)
                |> MaybeEx.join
            )
            (model.currentDiagram
                |> Maybe.map (\x -> x.users)
                |> MaybeEx.join
            )
        , div
            [ class "main" ]
            [ lazy6 Menu.view (toRoute model.url) model.diagramModel.width model.window.fullscreen model.openMenu model.isOnline (Model.canWrite model)

            -- TODO:
            , lazy8 (mainView model.loginUser (Model.canWrite model) model.searchQuery model.settings) model.diagramModel model.diagrams model.timezone model.window model.tabIndex model.text model.url model.filterDiagramList
            ]
        ]


sharingDialogView : Route -> Maybe User -> Maybe String -> Maybe ShareUrl -> Maybe String -> Maybe String -> Maybe (List DiagramUser) -> Html Msg
sharingDialogView route user embedUrl shareUrl inviteMailAddress ownerId users =
    case route of
        SharingSettings ->
            case ( user, shareUrl, embedUrl ) of
                ( Just u, Just (ShareUrl url), Just e ) ->
                    ShareDialog.view
                        (inviteMailAddress
                            |> Maybe.withDefault ""
                        )
                        (u.id == Maybe.withDefault "" ownerId)
                        e
                        url
                        u
                        users

                _ ->
                    Empty.view

        _ ->
            Empty.view


mainView : Maybe User -> Bool -> Maybe String -> Settings -> DiagramModel.Model -> Maybe (List DiagramItem) -> Maybe Zone -> Window -> Int -> String -> Url.Url -> Maybe String -> Html Msg
mainView user canWrite searchQuery settings diagramModel diagrams zone window tabIndex text url filterDiagramList =
    let
        mainWindow =
            if diagramModel.width > 0 && Utils.isPhone diagramModel.width then
                lazy4 SwitchWindow.view
                    diagramModel.settings.backgroundColor
                    tabIndex

            else
                lazy5 SplitWindow.view
                    canWrite
                    diagramModel.settings.backgroundColor
                    window
    in
    case toRoute url of
        Route.List ->
            lazy5 DiagramList.view user (zone |> Maybe.withDefault Time.utc) searchQuery diagrams filterDiagramList

        _ ->
            mainWindow
                (lazy2 Editor.view settings (toRoute url))
                (if String.isEmpty text then
                    Logo.view

                 else
                    lazy Diagram.view { diagramModel | showMiniMap = Maybe.withDefault True <| settings.miniMap }
                        |> Html.map UpdateDiagram
                )


main : Program ( String, Settings ) Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , view =
            \m ->
                { title = Maybe.withDefault "untitled" m.title ++ " | TextUSM"
                , body = [ view m ]
                }
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }


showProgressbar : Bool -> Html Msg
showProgressbar show =
    if show then
        ProgressBar.view

    else
        div [ style "height" "4px", style "background" "#273037" ] []


showNotification : Maybe Notification -> Html Msg
showNotification notify =
    case notify of
        Just notification ->
            Notification.view notification

        Nothing ->
            Empty.view


networkStatus : Bool -> Html Msg
networkStatus isOnline =
    if isOnline then
        Empty.view

    else
        div
            [ style "position" "fixed"
            , style "top" "40px"
            , style "right" "10px"
            , style "z-index" "10"
            ]
            [ Icon.cloudOff 24 ]



-- Update


changeRouteTo : Route -> Model -> ( Model, Cmd Msg )
changeRouteTo route model =
    let
        updatedModel =
            { model | diagrams = Nothing }

        getCmds : List (Cmd Msg) -> Cmd Msg
        getCmds cmds =
            Cmd.batch (Task.perform Init Dom.getViewport :: cmds)

        changeDiagramType : DiagramType -> ( Model, Cmd Msg )
        changeDiagramType type_ =
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | diagramType = type_ }
            in
            ( { updatedModel | diagramModel = newDiagramModel }
            , getCmds
                [ if type_ == DiagramType.Markdown then
                    setEditorLanguage "markdown"

                  else
                    setEditorLanguage "userStoryMap"
                ]
            )
    in
    case route of
        Route.List ->
            ( updatedModel, getCmds [ getDiagrams () ] )

        Route.Settings ->
            ( updatedModel, getCmds [] )

        Route.Help ->
            ( updatedModel, getCmds [] )

        Route.CallbackTrello (Just token) (Just code) ->
            let
                usm =
                    Diagram.update (DiagramModel.OnChangeText model.text) model.diagramModel

                req =
                    Api.Export.createRequest token
                        (Just code)
                        Nothing
                        usm.hierarchy
                        (Parser.parseComment model.text)
                        (if model.title == Just "" then
                            "UnTitled"

                         else
                            model.title |> Maybe.withDefault "UnTitled"
                        )
                        usm.items
            in
            ( { updatedModel
                | progress = True
              }
            , getCmds
                [ Task.perform identity (Task.succeed (OnNotification (Info "Start export to Trello." Nothing)))
                , Task.attempt Exported (Api.Export.export model.apiRoot Api.Export.Trello req)
                ]
            )

        Route.Embed diagram title path ->
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel
                        | diagramType =
                            DiagramType.fromString diagram
                    }
            in
            ( { updatedModel
                | window =
                    { position = model.window.position
                    , moveStart = model.window.moveStart
                    , moveX = model.window.moveX
                    , fullscreen = True
                    }
                , diagramModel = newDiagramModel
                , title =
                    if title == "untitled" then
                        Nothing

                    else
                        Just title
              }
            , getCmds [ decodeShareText path ]
            )

        Route.Share diagram title path ->
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel
                        | diagramType =
                            DiagramType.fromString diagram
                    }
            in
            ( { updatedModel
                | diagramModel = newDiagramModel
                , title =
                    if title == "untitled" then
                        Nothing

                    else
                        percentDecode title
              }
            , getCmds [ decodeShareText path ]
            )

        Route.UsmView settingsJson ->
            changeRouteTo (Route.View "usm" settingsJson) updatedModel

        Route.View diagram settingsJson ->
            let
                maybeSettings =
                    percentDecode settingsJson
                        |> Maybe.andThen
                            (\x ->
                                D.decodeString settingsDecoder x |> Result.toMaybe
                            )

                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel
                        | diagramType =
                            DiagramType.fromString diagram
                    }

                updatedDiagramModel =
                    case maybeSettings of
                        Just settings ->
                            { newDiagramModel | settings = settings.storyMap, showZoomControl = False, fullscreen = True }

                        Nothing ->
                            { newDiagramModel | showZoomControl = False, fullscreen = True }
            in
            case maybeSettings of
                Just settings ->
                    ( { updatedModel
                        | settings = settings
                        , diagramModel = updatedDiagramModel
                        , window =
                            { position = model.window.position
                            , moveStart = model.window.moveStart
                            , moveX = model.window.moveX
                            , fullscreen = True
                            }
                        , text = String.replace "\\n" "\n" (settings.text |> Maybe.withDefault "")
                        , title = settings.title
                      }
                    , getCmds []
                    )

                Nothing ->
                    ( updatedModel, getCmds [] )

        Route.BusinessModelCanvas ->
            changeDiagramType DiagramType.BusinessModelCanvas

        Route.OpportunityCanvas ->
            changeDiagramType DiagramType.OpportunityCanvas

        Route.FourLs ->
            changeDiagramType DiagramType.FourLs

        Route.StartStopContinue ->
            changeDiagramType DiagramType.StartStopContinue

        Route.Kpt ->
            changeDiagramType DiagramType.Kpt

        Route.Persona ->
            changeDiagramType DiagramType.UserPersona

        Route.Markdown ->
            changeDiagramType DiagramType.Markdown

        Route.MindMap ->
            changeDiagramType DiagramType.MindMap

        _ ->
            changeDiagramType DiagramType.UserStoryMap


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        NoOp ->
            ( model, Cmd.none )

        UpdateDiagram subMsg ->
            case subMsg of
                DiagramModel.ItemClick item ->
                    ( model, selectLine (item.lineNo + 1) )

                DiagramModel.OnResize _ _ ->
                    ( { model | diagramModel = Diagram.update subMsg model.diagramModel }, loadEditor model.text )

                DiagramModel.PinchIn _ ->
                    ( { model | diagramModel = Diagram.update subMsg model.diagramModel }, Task.perform identity (Task.succeed (UpdateDiagram DiagramModel.ZoomIn)) )

                DiagramModel.PinchOut _ ->
                    ( { model | diagramModel = Diagram.update subMsg model.diagramModel }, Task.perform identity (Task.succeed (UpdateDiagram DiagramModel.ZoomOut)) )

                DiagramModel.ToggleFullscreen ->
                    let
                        window =
                            model.window

                        newWindow =
                            { window | fullscreen = not window.fullscreen }
                    in
                    ( { model | window = newWindow, diagramModel = Diagram.update subMsg model.diagramModel }
                    , if newWindow.fullscreen then
                        openFullscreen ()

                      else
                        closeFullscreen ()
                    )

                DiagramModel.OnChangeText text ->
                    let
                        diagramModel =
                            Diagram.update subMsg model.diagramModel
                    in
                    case diagramModel.error of
                        Just err ->
                            ( { model | text = text, diagramModel = diagramModel }, errorLine err )

                        Nothing ->
                            ( { model | text = text, diagramModel = diagramModel }, errorLine "" )

                _ ->
                    ( { model | diagramModel = Diagram.update subMsg model.diagramModel }, Cmd.none )

        Init window ->
            let
                usm =
                    Diagram.update (DiagramModel.Init model.diagramModel.settings window model.text) model.diagramModel
            in
            case usm.error of
                Just err ->
                    ( { model
                        | diagramModel = usm
                        , progress = False
                      }
                    , Cmd.batch
                        [ errorLine err
                        , loadEditor model.text
                        ]
                    )

                Nothing ->
                    ( { model
                        | diagramModel = usm
                        , progress = False
                      }
                    , loadEditor model.text
                    )

        GotTimeZone zone ->
            ( { model | timezone = Just zone }, Cmd.none )

        DownloadCompleted ( x, y ) ->
            let
                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | x = x, y = y, matchParent = False }
            in
            ( { model | diagramModel = newDiagramModel }, Cmd.none )

        Download fileType ->
            let
                ( width, height ) =
                    Utils.getCanvasSize model.diagramModel

                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | x = 0, y = 0, matchParent = True }

                ( sub, extension ) =
                    case fileType of
                        Png ->
                            ( downloadPng, ".png" )

                        Pdf ->
                            ( downloadPdf, ".pdf" )

                        Svg ->
                            ( downloadSvg, ".svg" )
            in
            ( { model | diagramModel = newDiagramModel }
            , sub
                { width = width
                , height = height
                , id = "usm"
                , title = Utils.getTitle model.title ++ extension
                , x = model.diagramModel.x
                , y = model.diagramModel.y
                }
            )

        StartDownloadSvg image ->
            ( model, Cmd.batch [ Download.string (Utils.getTitle model.title ++ ".svg") "image/svg+xml" image, Task.perform identity (Task.succeed CloseMenu) ] )

        OpenMenu menu ->
            ( { model | openMenu = Just menu }, Cmd.none )

        CloseMenu ->
            ( { model | openMenu = Nothing }, Cmd.none )

        FileSelect ->
            ( model, Select.file [ "text/plain", "text/markdown" ] FileSelected )

        FileSelected file ->
            ( { model | title = Just (File.name file) }, Utils.fileLoad file FileLoaded )

        FileLoaded text ->
            ( model, Cmd.batch [ Task.perform identity (Task.succeed (UpdateDiagram (DiagramModel.OnChangeText text))), loadText text ] )

        Search query ->
            ( { model
                | searchQuery =
                    if String.isEmpty query then
                        Nothing

                    else
                        Just query
              }
            , Cmd.none
            )

        SaveToFileSystem ->
            let
                title =
                    model.title |> Maybe.withDefault ""
            in
            ( model, Download.string title "text/plain" model.text )

        Save ->
            let
                isRemote =
                    isJust model.loginUser
            in
            if isNothing model.title then
                let
                    ( model_, cmd_ ) =
                        update StartEditTitle model
                in
                ( model_, cmd_ )

            else if Model.canWrite model then
                let
                    title =
                        model.title |> Maybe.withDefault ""

                    isLocal =
                        Maybe.map (\d -> not d.isRemote) model.currentDiagram |> Maybe.withDefault True
                in
                ( { model
                    | notification =
                        if not isRemote then
                            Just (Info ("Successfully \"" ++ title ++ "\" saved.") Nothing)

                        else
                            Nothing
                  }
                , Cmd.batch
                    [ saveDiagram
                        { id =
                            if (isNothing model.currentDiagram || isLocal) && isRemote then
                                Nothing

                            else
                                model.id
                        , title = title
                        , text = model.text
                        , thumbnail = Nothing
                        , diagramPath = DiagramType.toString model.diagramModel.diagramType
                        , isRemote = isRemote
                        , updatedAt = Nothing
                        , users = Nothing
                        , isPublic = False
                        , ownerId =
                            model.currentDiagram
                                |> Maybe.map (\x -> x.ownerId)
                                |> MaybeEx.join
                        }
                    , if not isRemote then
                        Utils.delay 3000 OnCloseNotification

                      else
                        Cmd.none
                    ]
                )

            else
                ( model, Cmd.none )

        SaveToRemote diagram ->
            let
                save =
                    DiagramApi.save (Utils.getIdToken model.loginUser) model.apiRoot diagram
                        |> Task.map (\x -> diagram)
            in
            ( { model | progress = True }, Task.attempt Saved save )

        Saved (Err _) ->
            let
                item =
                    { id = model.id
                    , title = model.title |> Maybe.withDefault ""
                    , text = model.text
                    , thumbnail = Nothing
                    , diagramPath = DiagramType.toString model.diagramModel.diagramType
                    , isRemote = False
                    , updatedAt = Nothing
                    , users = Nothing
                    , isPublic = False
                    , ownerId = Nothing
                    }
            in
            ( { model
                | progress = False
                , currentDiagram = Just item
              }
            , Cmd.batch
                [ Utils.delay 3000
                    OnCloseNotification
                , Utils.showWarningMessage ("Successfully \"" ++ (model.title |> Maybe.withDefault "") ++ "\" saved.") Nothing
                , saveDiagram item
                ]
            )

        Saved (Ok diagram) ->
            let
                newDiagram =
                    { diagram | ownerId = Just (model.loginUser |> Maybe.map (\u -> u.id) |> Maybe.withDefault "") }
            in
            ( { model | currentDiagram = Just newDiagram, progress = False }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification
                , Utils.showInfoMessage ("Successfully \"" ++ (model.title |> Maybe.withDefault "") ++ "\" saved.") Nothing
                ]
            )

        SelectAll id ->
            ( model, selectTextById id )

        Shortcuts x ->
            if x == "save" then
                update Save model

            else if x == "open" then
                update GetDiagrams model

            else
                ( model, Cmd.none )

        StartEditTitle ->
            ( { model | isEditTitle = True }
            , Task.attempt
                (\_ -> NoOp)
              <|
                Dom.focus "title"
            )

        EndEditTitle code isComposing ->
            if code == 13 && not isComposing then
                ( { model | isEditTitle = False }, Cmd.none )

            else
                ( model, Cmd.none )

        EditTitle title ->
            ( { model
                | title =
                    if String.isEmpty title then
                        Nothing

                    else
                        Just title
              }
            , Cmd.none
            )

        EditSettings ->
            ( model
            , Nav.pushUrl model.key (Route.toString Route.Settings)
            )

        ShowHelp ->
            ( model
            , Nav.pushUrl model.key (Route.toString Route.Help)
            )

        ApplySettings settings ->
            let
                diagramModel =
                    model.diagramModel

                storyMapSettings =
                    settings.storyMap

                newStoryMapSettings =
                    { storyMapSettings | font = settings.font }

                newDiagramModel =
                    { diagramModel | settings = newStoryMapSettings }
            in
            ( { model | settings = settings, diagramModel = newDiagramModel }, Cmd.none )

        OnVisibilityChange visible ->
            if model.window.fullscreen then
                ( model, Cmd.none )

            else if visible == Hidden then
                let
                    storyMap =
                        model.settings.storyMap

                    newStoryMap =
                        { storyMap | font = model.settings.font }

                    newSettings =
                        { position = Just model.window.position
                        , font = model.settings.font
                        , diagramId = model.id
                        , storyMap = newStoryMap
                        , text = Just model.text
                        , title =
                            model.title
                        , miniMap =
                            model.settings.miniMap
                        , github = model.settings.github
                        }
                in
                ( { model | settings = newSettings }
                , saveSettings newSettings
                )

            else
                ( model, Cmd.none )

        OnStartWindowResize x ->
            ( { model
                | window =
                    { position = model.window.position
                    , moveStart = True
                    , moveX = x
                    , fullscreen = model.window.fullscreen
                    }
              }
            , Cmd.none
            )

        Stop ->
            ( { model
                | window =
                    { position = model.window.position
                    , moveStart = False
                    , moveX = model.window.moveX
                    , fullscreen = model.window.fullscreen
                    }
              }
            , Cmd.none
            )

        OnWindowResize x ->
            ( { model
                | window =
                    { position = model.window.position + x - model.window.moveX
                    , moveStart = True
                    , moveX = x
                    , fullscreen = model.window.fullscreen
                    }
              }
            , Cmd.none
            )

        OnCurrentShareUrl ->
            if isJust model.loginUser then
                let
                    loadUsers =
                        DiagramApi.item (Utils.getIdToken model.loginUser) model.apiRoot (model.id |> Maybe.withDefault "")
                in
                ( { model | progress = True }
                , Cmd.batch
                    [ encodeShareText
                        { diagramType =
                            DiagramType.toString model.diagramModel.diagramType
                        , title = model.title
                        , text = model.text
                        }
                    , Task.attempt LoadUsers loadUsers
                    ]
                )

            else
                update Login model

        LoadUsers (Err e) ->
            ( { model | progress = False }, Cmd.none )

        LoadUsers (Ok res) ->
            ( { model
                | progress = False
                , currentDiagram = Just res
              }
            , Cmd.none
            )

        GetShortUrl (Err e) ->
            ( { model | progress = False }
            , Cmd.batch
                [ Task.perform identity (Task.succeed (OnNotification (Error ("Error. " ++ Utils.httpErrorToString e))))
                , Utils.delay 3000 OnCloseNotification
                ]
            )

        GetShortUrl (Ok res) ->
            ( { model
                | progress = False
                , share = Just (ShareUrl res.shortLink)
              }
            , Nav.pushUrl model.key (Route.toString Route.SharingSettings)
            )

        OnShareUrl shareInfo ->
            ( model
            , encodeShareText shareInfo
            )

        CancelSharing ->
            ( { model | share = Nothing, inviteMailAddress = Nothing }, Nav.back model.key 1 )

        InviteUser ->
            let
                addUser =
                    case model.loginUser of
                        Just user ->
                            Task.attempt AddUser (DiagramApi.addUser (Utils.getIdToken model.loginUser) model.apiRoot { diagramID = Maybe.withDefault "" model.id, mail = model.inviteMailAddress |> Maybe.withDefault "" })

                        Nothing ->
                            Cmd.none
            in
            ( { model | progress = True, share = Nothing, inviteMailAddress = Nothing }, addUser )

        AddUser (Err e) ->
            ( { model | progress = False }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification, Utils.showErrorMessage "Faild add user" ]
            )

        AddUser (Ok res) ->
            let
                users =
                    Maybe.map (\u -> res :: u)
                        (model.currentDiagram
                            |> Maybe.map (\x -> x.users)
                            |> MaybeEx.join
                        )

                currentDiagram =
                    model.currentDiagram
                        |> Maybe.map (\x -> { x | users = users })
            in
            ( { model | currentDiagram = currentDiagram, progress = False }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification, Utils.showInfoMessage ("Successfully add \"" ++ res.name ++ "\"") Nothing ]
            )

        DeleteUser userId ->
            let
                deleteTask =
                    DiagramApi.deleteUser (Utils.getIdToken model.loginUser) model.apiRoot userId (Maybe.withDefault "" model.id)
                        |> Task.map (\_ -> userId)
            in
            ( { model | progress = True }, Task.attempt DeletedUser deleteTask )

        DeletedUser (Err e) ->
            ( { model | progress = False }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification
                , Utils.showInfoMessage "Faild to delete user." Nothing
                ]
            )

        DeletedUser (Ok userId) ->
            let
                users =
                    (model.currentDiagram
                        |> Maybe.map (\x -> x.users)
                        |> MaybeEx.join
                    )
                        |> Maybe.map (\u -> List.filter (\x -> x.id /= userId) u)

                currentDiagram =
                    model.currentDiagram
                        |> Maybe.map (\x -> { x | users = users })
            in
            ( { model | currentDiagram = currentDiagram, progress = False }, Cmd.none )

        OnNotification notification ->
            ( { model | notification = Just notification }, Cmd.none )

        OnAutoCloseNotification notification ->
            ( { model | notification = Just notification }, Utils.delay 3000 OnCloseNotification )

        OnCloseNotification ->
            ( { model | notification = Nothing }, Cmd.none )

        OnEncodeShareText path ->
            let
                shareUrl =
                    "https://app.textusm.com/share" ++ path

                embedUrl =
                    "https://app.textusm.com/embed" ++ path
            in
            ( { model | embed = Just embedUrl }, Task.attempt GetShortUrl (UrlShorterApi.urlShorter (Utils.getIdToken model.loginUser) model.apiRoot shareUrl) )

        OnChangeNetworkStatus isOnline ->
            ( { model | isOnline = isOnline }, Cmd.none )

        OnDecodeShareText text ->
            ( model, Task.perform identity (Task.succeed (FileLoaded text)) )

        WindowSelect tab ->
            ( { model | tabIndex = tab }, layoutEditor 100 )

        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            let
                updatedModel =
                    { model | url = url }
            in
            changeRouteTo (toRoute url) updatedModel

        GetAccessTokenForTrello ->
            ( model, Api.Export.getAccessToken model.apiRoot Api.Export.Trello )

        GetAccessTokenForGitHub ->
            ( model, getAccessTokenForGitHub () )

        Exported (Err e) ->
            ( { model | progress = False }
            , Cmd.batch
                [ Utils.showErrorMessage ("Error export. " ++ Utils.httpErrorToString e)
                , Nav.pushUrl model.key (Route.toString Route.Home)
                ]
            )

        Exported (Ok result) ->
            let
                messageCmd =
                    if result.failed > 0 then
                        Utils.showWarningMessage "Finish export, but some errors occurred. Click to open Trello." (Just result.url)

                    else
                        Utils.showInfoMessage "Finish export. Click to open Trello." (Just result.url)
            in
            ( { model | progress = False }
            , Cmd.batch
                [ messageCmd
                , Nav.pushUrl model.key (Route.toString Route.Home)
                ]
            )

        DoOpenUrl url ->
            ( model, Nav.load url )

        ExportGitHub token ->
            let
                req =
                    Maybe.map
                        (\g ->
                            Api.Export.createRequest
                                token
                                Nothing
                                (Just
                                    { owner = g.owner
                                    , repo = g.repo
                                    }
                                )
                                model.diagramModel.hierarchy
                                (Parser.parseComment model.text)
                                (if model.title == Just "" then
                                    "untitled"

                                 else
                                    model.title |> Maybe.withDefault "untitled"
                                )
                                model.diagramModel.items
                        )
                        model.settings.github
            in
            ( { model
                | progress = isJust req
              }
            , case req of
                Just r ->
                    Cmd.batch
                        [ Utils.showInfoMessage "Start export to Github." Nothing
                        , Task.attempt Exported (Api.Export.export model.apiRoot Api.Export.Github r)
                        ]

                Nothing ->
                    Cmd.batch
                        [ Utils.showWarningMessage "Invalid settings. Please add GitHub Owner and Repository to settings." Nothing
                        , Task.perform identity (Task.succeed EditSettings)
                        ]
            )

        GotLocalDiagrams localItems ->
            case model.loginUser of
                Just _ ->
                    let
                        remoteItems =
                            DiagramApi.items (Maybe.map (\u -> UserModel.getIdToken u) model.loginUser) 1 model.apiRoot

                        items =
                            remoteItems
                                |> Task.map
                                    (\item ->
                                        List.concat [ localItems, item ]
                                            |> List.sortWith
                                                (\a b ->
                                                    let
                                                        v1 =
                                                            a.updatedAt |> Maybe.withDefault 0

                                                        v2 =
                                                            b.updatedAt |> Maybe.withDefault 0
                                                    in
                                                    if v1 - v2 > 0 then
                                                        LT

                                                    else if v1 - v2 < 0 then
                                                        GT

                                                    else
                                                        EQ
                                                )
                                    )
                                |> Task.mapError (Tuple.pair localItems)
                    in
                    ( { model | progress = True }, Task.attempt GotDiagrams items )

                Nothing ->
                    ( { model | diagrams = Just localItems }, Cmd.none )

        GotDiagrams (Err ( items, err )) ->
            ( { model | progress = False, diagrams = Just items }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification
                , Utils.showWarningMessage "Failed to load files." Nothing
                ]
            )

        GotDiagrams (Ok items) ->
            ( { model | progress = False, diagrams = Just items }, Cmd.none )

        GetDiagrams ->
            ( model, Nav.pushUrl model.key (Route.toString Route.List) )

        RemoveDiagram diagram ->
            ( model, removeDiagrams diagram )

        RemoveRemoteDiagram diagram ->
            ( model
            , Task.attempt Removed
                (DiagramApi.remove (Utils.getIdToken model.loginUser) model.apiRoot (diagram.id |> Maybe.withDefault "")
                    |> Task.mapError (Tuple.pair diagram)
                    |> Task.map (\_ -> diagram)
                )
            )

        Removed (Err ( diagram, _ )) ->
            ( model
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification
                , Utils.showErrorMessage
                    ("Failed \"" ++ diagram.title ++ "\" remove")
                ]
            )

        Removed (Ok diagram) ->
            ( model
            , Cmd.batch
                [ getDiagrams ()
                , Utils.delay 3000 OnCloseNotification
                , Utils.showInfoMessage
                    ("Successfully \"" ++ diagram.title ++ "\" removed")
                    Nothing
                ]
            )

        RemovedDiagram ( diagram, removed ) ->
            ( model
            , if removed then
                Cmd.batch
                    [ getDiagrams ()
                    , Utils.delay 3000 OnCloseNotification
                    , Utils.showInfoMessage
                        ("Successfully \"" ++ diagram.title ++ "\" removed")
                        Nothing
                    ]

              else
                Cmd.none
            )

        Open diagram ->
            if diagram.isRemote then
                ( { model | progress = True }
                , Task.attempt Opened
                    (DiagramApi.item (Utils.getIdToken model.loginUser) model.apiRoot (diagram.id |> Maybe.withDefault "")
                        |> Task.mapError (Tuple.pair diagram)
                    )
                )

            else
                ( { model
                    | id = diagram.id
                    , text = diagram.text
                    , title = Just diagram.title
                    , currentDiagram = Just diagram
                  }
                , Nav.pushUrl model.key diagram.diagramPath
                )

        Opened (Err ( diagram, _ )) ->
            ( { model
                | progress = False
                , currentDiagram = Nothing
              }
            , Cmd.batch
                [ Utils.delay 3000 OnCloseNotification
                , Utils.showWarningMessage ("Failed to load \"" ++ diagram.title ++ "\".") Nothing
                ]
            )

        Opened (Ok diagram) ->
            ( { model
                | progress = False
                , id = diagram.id
                , text = diagram.text
                , title = Just diagram.title
                , currentDiagram = Just diagram
              }
            , Nav.pushUrl model.key diagram.diagramPath
            )

        UpdateSettings getSetting value ->
            let
                settings =
                    getSetting value

                diagramModel =
                    model.diagramModel

                newDiagramModel =
                    { diagramModel | settings = settings.storyMap }
            in
            ( { model | settings = settings, diagramModel = newDiagramModel }, Cmd.none )

        Login ->
            ( model, login () )

        Logout ->
            ( { model | loginUser = Nothing, currentDiagram = Nothing }, logout () )

        OnAuthStateChanged user ->
            ( { model | loginUser = user }, Cmd.none )

        HistoryBack ->
            ( { model | diagrams = Nothing }, Nav.back model.key 1 )

        MoveToBack ->
            ( model, Nav.back model.key 1 )

        EditInviteMail mail ->
            ( { model
                | inviteMailAddress =
                    if String.isEmpty mail then
                        Nothing

                    else
                        Just mail
              }
            , Cmd.none
            )

        UpdateRole userId role ->
            let
                updateRole =
                    case model.loginUser of
                        Just _ ->
                            Task.attempt UpdatedRole (DiagramApi.updateRole (Utils.getIdToken model.loginUser) model.apiRoot userId { diagramID = Maybe.withDefault "" model.id, role = role })

                        Nothing ->
                            Cmd.none
            in
            ( model, updateRole )

        UpdatedRole (Err e) ->
            ( model, Cmd.batch [ Utils.delay 3000 OnCloseNotification, Utils.showErrorMessage ("Update failed." ++ Utils.httpErrorToString e) ] )

        UpdatedRole (Ok res) ->
            let
                users =
                    model.currentDiagram
                        |> Maybe.map (\x -> x.users)
                        |> MaybeEx.join
                        |> Maybe.map
                            (\list ->
                                List.map
                                    (\u ->
                                        if u.id == res.id then
                                            { u | role = res.role }

                                        else
                                            u
                                    )
                                    list
                            )
            in
            ( model, Cmd.none )

        FilterDiagramList filter ->
            ( { model | filterDiagramList = filter }, Cmd.none )

        New type_ ->
            let
                ( text_, route_ ) =
                    case type_ of
                        DiagramType.UserStoryMap ->
                            ( "", Route.UserStoryMap )

                        DiagramType.BusinessModelCanvas ->
                            ( "👥 Key Partners\n📊 Customer Segments\n🎁 Value Proposition\n✅ Key Activities\n🚚 Channels\n💰 Revenue Streams\n🏷️ Cost Structure\n💪 Key Resources\n💙 Customer Relationships", Route.BusinessModelCanvas )

                        DiagramType.OpportunityCanvas ->
                            ( "Problems\nSolution Ideas\nUsers and Customers\nSolutions Today\nBusiness Challenges\nHow will Users use Solution?\nUser Metrics\nAdoption Strategy\nBusiness Benefits and Metrics\nBudget", Route.OpportunityCanvas )

                        DiagramType.FourLs ->
                            ( "Liked\nLearned\nLacked\nLonged for", Route.FourLs )

                        DiagramType.StartStopContinue ->
                            ( "Start\nStop\nContinue", Route.StartStopContinue )

                        DiagramType.Kpt ->
                            ( "K\nP\nT", Route.Kpt )

                        DiagramType.UserPersona ->
                            ( "Name\n    https://app.textusm.com/images/logo.svg\nWho am i...\nThree reasons to use your product\nThree reasons to buy your product\nMy interests\nMy personality\nMy Skills\nMy dreams\nMy relationship with technology", Route.Persona )

                        DiagramType.Markdown ->
                            ( "", Route.Markdown )

                        DiagramType.MindMap ->
                            ( "", Route.MindMap )

                displayText =
                    if String.isEmpty model.text then
                        text_

                    else
                        model.text
            in
            ( { model
                | id = Nothing
                , title = Nothing
                , text = displayText
                , currentDiagram = Nothing
              }
            , Cmd.batch [ loadText displayText, Nav.pushUrl model.key (Route.toString route_) ]
            )


saveToLocal : Model -> Cmd Msg
saveToLocal model =
    saveDiagram
        { id = Nothing
        , title = model.title |> Maybe.withDefault "backup"
        , text = model.text
        , thumbnail = Nothing
        , diagramPath = DiagramType.toString model.diagramModel.diagramType
        , isRemote = False
        , updatedAt = Nothing
        , users = Nothing
        , isPublic = False
        , ownerId =
            model.currentDiagram
                |> Maybe.map (\x -> x.ownerId)
                |> MaybeEx.join
        }
