# amis. Escrow Protocol Smart Contracts

Secure, decentralized escrow for digital asset trades.

---

## Overview

The `amis.` project is designed to facilitate trustless and secure digital asset trades, primarily through a Discord bot interface and a web-based frontend. This repository contains the core smart contract logic that underpins the escrow functionality, enabling users to confidently engage in peer-to-peer transactions.

While the comprehensive solution involves a private Discord bot backend and a private frontend application, this repository showcases the transparent and auditable smart contracts that govern the escrow process.

## High-Level Architecture

The `amis.` ecosystem comprises three main components:

1.  **Frontend (Private):** A web application for users to interact with the escrow system, manage trades, and connect their wallets. This component is kept private to protect proprietary UI/UX designs and integrations.
2.  **Backend Bot (Private):** A Discord bot and its associated backend services that handle user commands, orchestrate trade setups, manage Discord-specific interactions, and communicate with the smart contracts on behalf of users. This component is also private for intellectual property and security considerations.
3.  **Smart Contracts (Public - This Repository):** The Solidity smart contracts deployed on the blockchain that manage the escrow logic, USDC token transfers, and trade state. These contracts are fully open-source and auditable, forming the trust layer of the `amis.` protocol.

The Frontend and Backend Bot interact with these Smart Contracts to create, fund, and release escrowed assets, ensuring transparency and immutability for all trade participants.

## Technologies Used

*   **Smart Contracts (in this repo):**
    *   **Solidity:** For writing secure and efficient smart contracts.
    *   **Hardhat:** Ethereum development environment for compiling, testing, and deploying contracts.
*   **Frontend (not in this repo):**
    *   **React, Vite, Tailwind CSS:** Modern web development stack for a responsive and intuitive user interface.
    *   **Shadcn UI:** Reusable UI components for a polished design.
    *   **Wagmi, Ethers.js, AppKit:** Libraries for seamless blockchain interaction and wallet integration.
*   **Backend Bot (not in this repo):**
    *   **Node.js:** Runtime environment for the bot and backend services.
    *   **Supabase:** For database management and backend services.

## Smart Contract Details

This repository contains the `AmisEscrowUSDC.sol` smart contract, which is responsible for:

*   **Escrow Creation:** Allowing a buyer to create an escrow for a specific trade amount.
*   **USDC Handling:** Managing the deposit and release of USDC tokens.
*   **Trade State Management:** Tracking the status of each trade (e.g., funded, released, disputed).
*   **Security:** Ensuring that funds are released only under predefined conditions, typically by a multi-signature approval process involving the Discord bot or agreed-upon parties.

The contract is designed to be deployed on the Base network, with particular focus on the Base Sepolia testnet for development and testing.

## Getting Started (Smart Contract)

To compile and deploy the smart contract locally (e.g., on a Hardhat local network):

1.  **Clone this repository:**
    ```bash
    git clone https://github.com/tonyrav3n/amis-bot-live.git
    cd amis-bot-live/contracts
    ```
2.  **Install Hardhat dependencies:**
    ```bash
    npm install
    # or yarn install / pnpm install
    ```
3.  **Compile the contract:**
    ```bash
    npx hardhat compile
    ```
4.  **Run tests (optional but recommended):**
    ```bash
    npx hardhat test
    ```
5.  **Deploy to a local network:**
    ```bash
    npx hardhat run scripts/deploy.js --network localhost
    ```
    *(Note: The exact deployment script may vary based on your Hardhat configuration.)*

## Contact

You can reach me on Discord: `tonyrav3n` or X: `@0xtonyraven`.

## Screenshots

*(Placeholder: Please add screenshots of the frontend application interacting with the smart contracts here to visually showcase the project.)*
