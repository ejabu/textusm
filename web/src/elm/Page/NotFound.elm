module Page.NotFound exposing (view)

import Asset
import Html exposing (Html, div, img, text)
import Html.Attributes exposing (alt, class, style)


view : Html msg
view =
    div [ class "notfound" ]
        [ img [ class "keyframe anim", Asset.src Asset.logo, style "width" "32px", alt "NOT FOUND" ] []
        , div [ style "padding" "8px" ] [ text "NOT FOUND" ]
        ]
