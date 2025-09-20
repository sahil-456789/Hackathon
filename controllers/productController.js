// controllers/productController.js
import asyncHandler from "express-async-handler";
import { validationResult } from "express-validator";
import Product from "../models/Product.js";

// @desc   Create new product
// @route  POST /api/products
// @access Public (for now)
export const createProduct = asyncHandler(async (req, res) => {
  // simple express-validator usage
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(422).json({ errors: errors.array() });
  }

  const { name, description, price, category, inStock } = req.body;
  const product = new Product({ name, description, price, category, inStock });
  await product.save();
  res.status(201).json(product);
});

// @desc   Get all products (with simple pagination ?page=1&limit=10)
// @route  GET /api/products
export const getProducts = asyncHandler(async (req, res) => {
  let { page = 1, limit = 10 } = req.query;
  page = Number(page);
  limit = Number(limit);

  const skip = (page - 1) * limit;
  const total = await Product.countDocuments();
  const products = await Product.find()
    .skip(skip)
    .limit(limit)
    .sort({ createdAt: -1 });

  res.json({
    page,
    limit,
    total,
    pages: Math.ceil(total / limit),
    data: products,
  });
});

// @desc   Get single product
// @route  GET /api/products/:id
export const getProductById = asyncHandler(async (req, res) => {
  const prod = await Product.findById(req.params.id);
  if (!prod) {
    res.status(404);
    throw new Error("Product not found");
  }
  res.json(prod);
});

// @desc   Update product
// @route  PUT /api/products/:id
export const updateProduct = asyncHandler(async (req, res) => {
  const prod = await Product.findById(req.params.id);
  if (!prod) {
    res.status(404);
    throw new Error("Product not found");
  }

  const updates = req.body;
  Object.assign(prod, updates);
  await prod.save();
  res.json(prod);
});

// @desc   Delete product
// @route  DELETE /api/products/:id
export const deleteProduct = asyncHandler(async (req, res) => {
  const prod = await Product.findById(req.params.id);
  if (!prod) {
    res.status(404);
    throw new Error("Product not found");
  }
  await prod.remove();
  res.json({ message: "Product removed" });
});
