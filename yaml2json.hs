{-# language InstanceSigs        #-}
{-# language NamedFieldPuns      #-}
{-# language OverloadedStrings   #-}
{-# language ScopedTypeVariables #-}

import Control.Monad.State hiding ((>>))
import Control.Monad.ST (ST, runST)
import Data.Aeson
  (FromJSON, ToJSON, Value, (.:), (.:?), (.=), object, toJSON, withObject)
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.HashMap.Strict (HashMap)
import Data.IntMap (IntMap)
import Data.IntSet (IntSet)
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Monoid
import Data.Ord (comparing)
import Data.Text (Text, pack, unpack)
import Data.Tuple (swap)
import Data.Vector (Vector)
import Prelude hiding ((>>), id)
import System.Environment
import System.Exit
import System.IO

import qualified Data.Aeson as Json
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LByteString
import qualified Data.HashMap.Strict as HashMap
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import qualified Data.Vector.Algorithms.Merge as Vector
import qualified Data.Yaml as Yaml

type Author = Text
type File = Text
type Link = Text
type Title = Text

type AuthorId = Int
type FileId = Int
type LinkId = Int
type TitleId = Int

-- | A thing that came from a line in a file.
data Loc a = Loc
  { locFile :: !File
  , locLine :: !Int
  , locValue :: a
  }

-- | Paper object read from @papers.yaml@.
data PaperIn = PaperIn
  { paperInTitle :: !Title
  , paperInAuthors :: !(Vector Author)
  , paperInYear :: !(Maybe Int)
  , paperInReferences :: !(Vector Title)
  , paperInLinks :: !(Vector Link)
  }

instance FromJSON PaperIn where
  parseJSON :: Value -> Parser PaperIn
  parseJSON =
    withObject "paper" $ \o -> do
      title <- o .: "title"
      author <- o .:? "author"
      authors <- o .:? "authors"
      year <- o .:? "year"
      references <- o .:? "references"
      link <- o .:? "link"
      links <- o .:? "links"
      pure PaperIn
        { paperInTitle = title
        , paperInAuthors =
            case (author, authors) of
              (Nothing, Nothing) -> mempty
              (Nothing, Just xs) -> xs
              (Just x, Nothing) -> pure x
              (Just _, Just _) -> fail "Found both 'author' and 'authors'"
        , paperInYear = year
        , paperInReferences = fromMaybe mempty references
        , paperInLinks =
            case (link, links) of
              (Nothing, Nothing) -> mempty
              (Nothing, Just xs) -> xs
              (Just x, Nothing) -> pure x
              (Just _, Just _) -> fail "Found both 'link' and 'links'"
        }

-- | Paper object written to @papers.json@.
data PaperOut = PaperOut
  { paperOutTitle :: !TitleId
    -- ^ Paper title.
  , paperOutAuthors :: !(Vector AuthorId)
    -- ^ Paper authors.
  , paperOutYear :: !(Maybe Int)
    -- ^ Paper year.
  , paperOutReferences :: !(Vector TitleId)
    -- ^ Paper references.
  , paperOutLinks :: !(Vector LinkId)
    -- ^ Paper links.
  , paperOutFile :: !FileId
    -- ^ Yaml file the paper was parsed from.
  , paperOutLine :: !Int
    -- ^ Line number in yaml file.
  }

instance ToJSON PaperOut where
  toJSON paper =
    object
      (catMaybes
        [ pure ("title" .= paperOutTitle paper)
        , do
            guard (not (null (paperOutAuthors paper)))
            pure ("authors" .= paperOutAuthors paper)
        , ("year" .=) <$> paperOutYear paper
        , do
            guard (not (null (paperOutReferences paper)))
            pure ("references" .= paperOutReferences paper)
        , do
            guard (not (null (paperOutLinks paper)))
            pure ("links" .= paperOutLinks paper)
        , pure ("file" .= paperOutFile paper)
        , pure ("line" .= paperOutLine paper)
        ])

-- | The entire @papers.json@ blob:
--
--   - Array of papers
--   - Lookup tables for strings that we need not include over and over
--     (authors, titles, etc).
--
data PapersOut = PapersOut
  { papersOutTitles :: !(IntMap Title)
  , papersOutAuthors :: !(IntMap Author)
  , papersOutLinks :: !(IntMap Link)
  , paperOutFiles :: !(IntMap File)
  , papersOutPapers :: !(Vector PaperOut)
    -- ^ Invariant: a 'PaperOut's title, author, references, etc. will always
    -- be in 'IntMap's above.
  }

instance ToJSON PapersOut where
  toJSON papers =
    object
      [ "titles" .= papersOutTitles papers
      , "authors" .= papersOutAuthors papers
      , "links" .= papersOutLinks papers
      , "files" .= paperOutFiles papers
      , "papers" .= papersOutPapers papers
      ]

main :: IO ()
main = do
  filenames :: [FilePath] <-
    getArgs

  papers :: [Vector (Loc PaperIn)] <-
    traverse decodePapersYaml filenames

  papers
    & mconcat
    & transform
    & Json.encode
    & LByteString.putStr
 where
  decodePapersYaml :: FilePath -> IO (Vector (Loc PaperIn))
  decodePapersYaml file = do
    bytes :: ByteString <-
      ByteString.readFile file

    -- The 'yaml' library makes it hard to get source locations, so we hack it
    -- together here. We know each yaml file is an array, so just find the
    -- locations of all of the '-' (45) characters that follow newlines (10).
    --
    -- Incidentally, this hacky algorithm is the reason why all papers.yaml
    -- files must begin with a newline, because otherwise we'd miss the first
    -- entry.
    let lineNo :: Int -> Int
        lineNo =
          ByteString.elemIndices 10 bytes
            & zip [2..]
            & mapMaybe
                (\(n, c) -> do
                  guard (c < ByteString.length bytes - 1)
                  guard (ByteString.index bytes (c+1) == 45)
                  pure n)
            & Vector.fromList
            & (Vector.!)

    case Yaml.decodeEither bytes of
      Left err -> do
        hPutStrLn stderr err
        exitFailure
      Right values ->
        pure
          (Vector.imap
            (\i x ->
              Loc
                { locFile = pack file
                , locLine = lineNo i
                , locValue = x
                })
            values)

data S = S
  { sTitleIds :: !(HashMap Title TitleId)
  , sAuthorIds :: !(HashMap Author AuthorId)
  , sLinkIds :: !(HashMap Link LinkId)
  , sFileIds :: !(HashMap File FileId)
  , sTopLevelTitles :: !IntSet -- TitleIdSet
  , sNextTitleId :: !TitleId
  , sNextAuthorId :: !AuthorId
  , sNextLinkId :: !LinkId
  , sNextFileId :: !FileId
  }

transform :: Vector (Loc PaperIn) -> PapersOut
transform =
  mapM transform1
    >> (`runState` s0)
    >> ploop
 where
  s0 :: S
  s0 = S
    { sTitleIds = mempty
    , sAuthorIds = mempty
    , sLinkIds = mempty
    , sFileIds = mempty
    , sTopLevelTitles = mempty
    , sNextTitleId = 0
    , sNextAuthorId = 0
    , sNextLinkId = 0
    , sNextFileId = 0
    }

  ploop :: (Vector PaperOut, S) -> PapersOut
  ploop (papers, s) =
    PapersOut
      { papersOutTitles = titles
      , papersOutAuthors =
          foldMap
            (swap >> uncurry IntMap.singleton)
            (HashMap.toList (sAuthorIds s))
      , papersOutLinks =
          foldMap
            (swap >> uncurry IntMap.singleton)
            (HashMap.toList (sLinkIds s))
      , paperOutFiles =
          foldMap
            (swap >> uncurry IntMap.singleton)
            (HashMap.toList (sFileIds s))
      , papersOutPapers =
          vectorSortOn
            (paperOutTitle >> flip IntMap.lookup titles >> fmap Text.toLower)
            (papers <> hanging)
      }
   where
    titles :: IntMap Title
    titles =
      foldMap
        (swap >> uncurry IntMap.singleton)
        (HashMap.toList (sTitleIds s))

    -- Papers that were referenced but not defined at the top-level are made
    -- into a 'PaperOut' consisting of only a title.
    hanging :: Vector PaperOut
    hanging =
      sTitleIds s
        & HashMap.elems
        & filter ((`IntSet.member` sTopLevelTitles s) >> not)
        & map fromTitle
        & Vector.fromList
     where
      fromTitle :: TitleId -> PaperOut
      fromTitle id =
        PaperOut
          { paperOutTitle = id
          , paperOutAuthors = mempty
          , paperOutYear = Nothing
          , paperOutReferences = mempty
          , paperOutLinks = mempty
          , paperOutFile =
              case HashMap.lookup "papers.yaml" (sFileIds s) of
                Nothing -> error "No 'papers.yaml' file id"
                Just file -> file
          , paperOutLine = 0
          }

    vectorSortOn :: forall a b. Ord b => (a -> b) -> Vector a -> Vector a
    vectorSortOn f xs =
      runST go
     where
      go :: forall s. ST s (Vector a)
      go = do
        ys <- Vector.thaw xs
        Vector.sortBy (comparing f) ys
        Vector.freeze ys

transform1 :: Loc PaperIn -> State S PaperOut
transform1 Loc{locFile, locLine, locValue = paper} = do
  title_id :: TitleId <-
    getTitleId (paperInTitle paper)

  title_ids :: IntSet <-
    gets sTopLevelTitles

  if IntSet.member title_id title_ids
    then error ("Duplicate entry: " ++ unpack (paperInTitle paper))
    else modify' (\s -> s { sTopLevelTitles = IntSet.insert title_id title_ids })

  authors :: Vector AuthorId <-
    mapM getAuthorId (paperInAuthors paper)

  references :: Vector TitleId <-
    mapM getTitleId (paperInReferences paper)

  links :: Vector LinkId <-
    mapM getLinkId (paperInLinks paper)

  file :: FileId <-
    getFileId locFile

  pure PaperOut
    { paperOutTitle = title_id
    , paperOutAuthors = authors
    , paperOutYear = paperInYear paper
    , paperOutReferences = references
    , paperOutLinks = links
    , paperOutFile = file
    , paperOutLine = locLine
    }

getTitleId :: Title -> State S TitleId
getTitleId title = do
  s <- get

  case HashMap.lookup title (sTitleIds s) of
    Nothing -> do
      put s
        { sTitleIds = HashMap.insert title (sNextTitleId s) (sTitleIds s)
        , sNextTitleId = sNextTitleId s + 1
        }
      pure (sNextTitleId s)
    Just id ->
      pure id

getAuthorId :: Author -> State S AuthorId
getAuthorId author = do
  s <- get

  case HashMap.lookup author (sAuthorIds s) of
    Nothing -> do
      put s
        { sAuthorIds = HashMap.insert author (sNextAuthorId s) (sAuthorIds s)
        , sNextAuthorId = sNextAuthorId s + 1
        }
      pure (sNextAuthorId s)
    Just id ->
      pure id

getLinkId :: Link -> State S LinkId
getLinkId link = do
  s <- get

  case HashMap.lookup link (sLinkIds s) of
    Nothing -> do
      put s
        { sLinkIds = HashMap.insert link (sNextLinkId s) (sLinkIds s)
        , sNextLinkId = sNextLinkId s + 1
        }
      pure (sNextLinkId s)
    Just id ->
      pure id

getFileId :: File -> State S FileId
getFileId file = do
  s <- get

  case HashMap.lookup file (sFileIds s) of
    Nothing -> do
      put s
        { sFileIds = HashMap.insert file (sNextFileId s) (sFileIds s)
        , sNextFileId = sNextFileId s + 1
        }
      pure (sNextFileId s)
    Just id ->
      pure id

(>>) :: (a -> b) -> (b -> c) -> (a -> c)
(>>) = flip (.)
