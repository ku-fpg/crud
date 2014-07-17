{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import           Control.Monad.IO.Class (liftIO) 

import           Data.Aeson
import qualified Data.ByteString.Lazy as BS
import           Data.Char (chr, isDigit)
import qualified Data.HashMap.Strict as HashMap
import           Data.List
import qualified Data.Set as Set
import           Data.Set (Set)
import qualified Data.Text as Text
import           Data.Text (Text, pack, unpack)

import           System.Environment
import           System.IO

import           Web.Scotty as Scotty hiding (raw)
import           Web.Scotty.CRUD
import           Web.Scotty.CRUD.JSON

main :: IO ()
main = do
        args <- getArgs
        let (flags,opts) = span ("--" `isPrefixOf`) args
        case opts of
          ("compress":opts') | null flags -> compress_main opts'
          ("table":opts')    | null opts' -> table_main flags
          ("update":opts')                -> update_main   opts'                            
          ("delta":opts')                 -> delta_main     opts'
          ("server":opts')                -> server_main   flags opts'                            
          _ -> error $ unlines
                [ "usage: crud [options] [command] [files]"
                , "         where command = compress | table | update | delta | server"
                , ""
                , "  -- compress a db"
                , "  crud compress < input.json > compressed-output.json"
                , "  crud compress db.json"
                , ""
                , "  -- output an ASCII table"
                , "  crud [--'<width>'] table < input.json | less"
                , "        --<width> : max width of each column (default 20)"
                , ""
                , "  -- update a db"
                , "  crud update db.json < new.json"
                , ""
                , "  -- find the delta differences between a db and a new-db"
                , "  crud delta db.json new-db.json"
                , ""
                , "  -- serve up a set of db's (names and URL paths are synonymous)"
                ,"   crud [--read-only|--local] server 3000 db.json [db2.json ...]"
                ]

------------------------------------------------------------------------------------------------------------

compress_main :: [String] -> IO ()
compress_main [] = do
        tab :: Table Row <- readTable stdin
        writeTable stdout tab
compress_main [db] = do
        h <- openBinaryFile db ReadMode
        tab :: Table Row <- readTable h
        hClose h
        h' <- openBinaryFile db WriteMode
        writeTable h' tab
        hClose h'
compress_main _ = error "crud compress: unknown options"

------------------------------------------------------------------------------------------------------------

table_main :: [String] -> IO ()
table_main ['-':'-':ns] | all isDigit ns && not (null ns) = do

        let mx = read ns

        -- Read what you can, please, into a Table.
        tab :: Table Row <- readTable stdin

--        print (HashMap.elems tab)
--        print (map HashMap.keys (HashMap.elems tab))
        
        let keys :: Set Text = Set.fromList $ pack "id" : concatMap HashMap.keys (HashMap.elems tab)
        
        let keyMx = id -- fmap (\ (k,v) -> (k,max (Text.length k) v))
                  $ sortBy (\ (k1,_) (k2,_) -> if k1 == k2 then EQ else
                                               if k1 == pack "id" then LT else
                                               if k2 == pack "id" then GT else
                                               compare k1 k2)
                  $ HashMap.toList
                  $ HashMap.fromListWith max $
                        [ (k',min mx $ length $ raw $ encode v') | (_k,v) <- HashMap.toList tab, (k',v') <- HashMap.toList v ] ++
                        [ (pack "id",Text.length k) | (k,_v) <- HashMap.toList tab] ++
                        [ (k,Text.length k) | k <- Set.toList keys ]


        let rjust txt n = take (n - length txt) (repeat ' ') ++ take n txt

--        putStrLn $ show [ (k,v) | (k,v) <- keyMx ]
        putStrLn $ unwords [ rjust (unpack k) v | (k,v) <- keyMx ]

        sequence_ [ putStrLn $ unwords [ case HashMap.lookup kk v' of
                                           Nothing -> rjust "-" kv
                                           Just o -> rjust o kv 
                                       | (kk,kv) <- keyMx 
                                       ]
                  | (k,v) <- HashMap.toList tab
                  , let v' = HashMap.insert (pack "id") (unpack k) $ fmap (raw . encode) v
                  ]
table_main [] = table_main ["--20"]
table_main _ = error "crud table: bad flags"
        
------------------------------------------------------------------------------------------------------------
        
update_main :: [String] -> IO ()
update_main [db] = update db
update_main _    = error "crud update: unknown options"

update ::  String -> IO ()
update db = do
    db_h <- openFile db AppendMode
    ups :: [TableUpdate Row] <- readTableUpdates stdin
    sequence_ [ writeTableUpdate db_h up
              | up <- ups
              ]
    hClose db_h
    return ()

------------------------------------------------------------------------------------------------------------
        
delta_main :: [String] -> IO ()
delta_main [db,db_new] = delta db db_new
delta_main _           = error "crud delta: unknown options"

-- What update would be required to turn the old db into the new db?
-- Can include deletes.
delta :: String -> String -> IO ()
delta db db_new = do
    old  :: Table Row <- openFile db     ReadMode >>= readTable
    new  :: Table Row <- openFile db_new ReadMode >>= readTable
    let iDs = HashMap.keys old ++ [ k | k <- HashMap.keys new, not (k `HashMap.member` old) ]
    sequence_ [ case (HashMap.lookup iD old,HashMap.lookup iD new) of
                  (_,     Just n)   -> writeTableUpdate stdout (RowUpdate (Named iD n :: Named Row))
                  (Just _,Nothing)  -> writeTableUpdate stdout (RowDelete iD :: TableUpdate Row)
                  (Nothing,Nothing) -> error "internal error"
              | iD <- iDs
              ]
 {-
    sequence_ [ do ans1 <- getRow crud iD
                   case HashMap.lookup ans1 of
                        Nothing             -> updateRow crud (Named iD row)
                        Just (Named _ row') -> updateRow crud (Named iD (f row row'))
-}
    return ()

------------------------------------------------------------------------------------------------------------

server_main :: [String] -> [String] -> IO ()
server_main _ (port:dbs) | all isDigit port && not (null port) = scotty (read port) $ do
  sequence_ [ do crud <- liftIO $ persistentCRUD db
                 scottyCRUD ('/':db) (crud :: CRUD Row)
            | db <- dbs 
            ]

server_main _ _ = error "crud server: unknown options"


------------------------------------------------------------------------------------------------------------

-- Get the raw ASCII text, please
raw :: BS.ByteString -> String
raw = map (chr.fromIntegral) . BS.unpack        
        