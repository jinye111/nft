



// contract MyNFT is ERC721URIStorage, Ownable {
//     uint256 private _nextTokenId;

//     constructor() ERC721("MyNFT", "MNFT") Ownable(msg.sender) {}

//     function safeMint(address to, string memory uri) public onlyOwner {
//         uint256 tokenId = _nextTokenId++;
//         _safeMint(to, tokenId);
//         _setTokenURI(tokenId, uri);
//     }
// }