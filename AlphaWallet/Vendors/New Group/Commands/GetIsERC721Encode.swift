//
// Created by James Sangalli on 14/7/18.
//

import Foundation
import TrustKeystore

struct GetIsERC721Encode: Web3Request {
    typealias Response = String

    static let abi = "{ \"constant\": true, \"inputs\": [ { \"name\": \"interfaceID\", \"type\": \"bytes4\" } ], \"name\": \"supportsInterface\", \"outputs\": [ { \"name\": \"\", \"type\": \"bool\" } ], \"payable\": false, \"stateMutability\": \"view\", \"type\": \"function\" }"
    
    var type: Web3RequestType {
        let run = "web3.eth.abi.encodeFunctionCall(\(GetIsERC721Encode.abi), [\"\(Constants.erc721InterfaceHash)\"])"
        return .script(command: run)
    }
}

struct GetIsERC721Decode: Web3Request {
    typealias Response = String

    let data: String

    var type: Web3RequestType {
        let run = "web3.eth.abi.decodeParameter('uint256', '\(data)')"
        return .script(command: run)
    }
}
